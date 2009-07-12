#!/usr/bin/ruby

require 'csv'  # for quoted-string splitting!
require 'logger'
require 'thread'
require 'xmpp4r'
require 'xmpp4r/iq'
require 'xmpp4r/message'
require 'xmpp4r/presence'
require 'xmpp4r/roster'
require 'yaml'

AUTH_FILE  = "#{ENV['HOME']}/.smartychat_auth"
STATE_FILE = "#{ENV['HOME']}/.smartychat_state"


# Queues messages, batching them together per-user before sending.
# This attempts to avoid hitting rate limits.
class MessageSender
  attr_accessor :logger

  def initialize(client, interval_sec=2, logger=nil)
    @client = client
    @interval_sec = interval_sec

    @logger = logger ? logger : Logger.new(STDOUT)
    @last_send_time = 0

    # JID -> [msg1, msg2, etc.]
    @queued_messages = {}
    @queued_messages_mutex = Mutex.new
    @queued_messages_condition = ConditionVariable.new

    @thread = Thread.new { loop { send_queued_messages } }
  end

  def enqueue_message(jid, text)
    @logger.debug("Enqueuing message for #{jid}")
    @queued_messages_mutex.synchronize do
      msg_list = @queued_messages[jid]
      if not msg_list
        msg_list = []
        @queued_messages[jid] = msg_list
      end
      msg_list << text

      # Wake up send_queued_messages().
      @queued_messages_condition.broadcast
    end
  end

  def send_queued_messages
    # Wait until there are some queued messages.
    @logger.debug('Waiting for new messages')
    @queued_messages_mutex.synchronize do
      loop do
        break if not @queued_messages.empty?
        @queued_messages_condition.wait @queued_messages_mutex
      end
    end

    # Wait a bit if we sent the previous batch recently.
    time_to_sleep = [@interval_sec - (Time.now.to_f - @last_send_time), 0].max
    @logger.debug("Sleeping #{time_to_sleep} sec before sending messages")
    sleep(time_to_sleep)

    messages = {}
    @queued_messages_mutex.synchronize do
      messages = @queued_messages
      @queued_messages = {}
    end

    uncondensed_messages = 0
    condensed_messages = 0
    messages.each do |jid, list|
      next if list.empty?
      uncondensed_messages += list.size
      body = list.join("\n")
      msg = Jabber::Message.new(jid, body)
      msg.type = :chat
      @client.send(msg)
      condensed_messages += 1
    end

    @logger.debug("Sent #{condensed_messages} message(s) " +
                  "(#{uncondensed_messages} uncondensed)")
    @last_send_time = Time.now.to_f
  end
end


# A single user.  Each JID has a User object associated with it.
class User
  attr_reader :jid, :nick
  attr_accessor :channel, :welcome_sent

  def initialize(sender, jid, nick=nil)
    @sender = sender
    @jid = jid
    @nick = (nick or jid)
    if @nick == jid and /^([^@]+)/ =~ jid
      @nick = $1
    end
    @channel = nil
    @welcome_sent = false
  end

  # Change the user's nick.  Returns false for invalid names.
  def change_nick(new_nick)
    return false if not new_nick =~ /^[-_.a-zA-Z0-9]+$/
    @nick = new_nick
    return true
  end

  def enqueue_message(text)
    @sender.enqueue_message(@jid, text)
  end

  def send_welcome
    usage =
      "Welcome to SmartyChat!  You'll need to join a channel using " +
      "*/join* before you can start chatting."
    enqueue_message(usage)
    enqueue_message("Send */help* if you're stuck.")
    @welcome_sent = true
  end

  # Get the user's state as a Hash that can be restored later.
  def serialize
    {
      'jid' => @jid,
      'nick' => @nick,
      'channel_name' => (@channel ? @channel.name : nil),
    }
  end

  # Construct a new user from the data returned by serialize().
  # If the user was subscribed to a channel, they are re-added to it.
  def User.deserialize(chat, struct)
    user = User.new(chat.sender, struct['jid'], struct['nick'])
    if struct['channel_name']
      user.channel = chat.get_channel(struct['channel_name'], false)
      user.channel.add_user(user) if user.channel
    end
    user.welcome_sent = true
    user
  end
end


# A channel where users can chat.
class Channel
  attr_reader :name, :users, :scores
  attr_accessor :password

  def initialize(name)
    @name = name
    @users = []
    @password = nil

    # String => Integer
    @scores = {}
  end

  def add_user(user)
    return if @users.include?(user)
    @users << user
  end

  def remove_user(user)
    return if not @users.include?(user)
    @users.delete(user)
  end

  # Repeat a typed message to all users except the one who sent it.
  def repeat_message(sender, body)
    text = "*#{sender.nick}:* #{body}"
    @users.each do |u|
      next if u == sender
      u.enqueue_message(text)
    end
  end

  # Broadcast a message to all users in the channel.
  def broadcast_message(text)
    @users.each {|u| u.enqueue_message(text) }
  end

  def increment_score(item, note=nil)
    words = %w{Hooray! Yay!}
    exclamation = words[rand(words.size)]
    @scores[item] = 0 if not @scores[item]
    @scores[item] += 1

    broadcast_message(
      "_#{exclamation} #{item} -> #{@scores[item]}" +
      "#{note ? " (#{note})" : ''}_")
  end

  def decrement_score(item, note=nil)
    words = %w{Ouch! Zing!}
    exclamation = words[rand(words.size)]
    @scores[item] = 0 if not @scores[item]
    @scores[item] -= 1

    broadcast_message(
      "_#{exclamation} #{item} -> #{@scores[item]}" +
      "#{note ? " (#{note})" : ''}_")
  end

  # Get the channel's state as a Hash that can be restored later.
  def serialize
    {
      'name' => @name,
      'password' => @password,
      'scores' => Hash[*(@scores.find_all {|k,v| v != 0 }.flatten)],
    }
  end

  # Construct a new channel from the data returned by serialize().
  def Channel.deserialize(chat, struct)
    channel = Channel.new(struct['name'])
    if struct['password'] and not struct['password'].empty?
      channel.password = struct['password']
    end
    struct['scores'].each {|k,v| channel.scores[k] = v.to_i }
    channel
  end
end


class SmartyChat
  attr_reader :state_mutex, :commands
  attr_accessor :sender, :logger

  def initialize(jid, password, state_file, logger=nil)
    @client = Jabber::Client.new(Jabber::JID.new(jid))
    @client.connect
    @client.auth(password)
    @client.add_message_callback {|m| handle_message(m) }
    @client.add_presence_callback {|p| handle_presence(p) }

    @roster = Jabber::Roster::Helper.new(@client)
    @roster.add_subscription_request_callback do |item, presence|
      handle_subscription_request(item, presence)
    end

    @client.send(Jabber::Presence.new)

    # JID -> User
    @users = {}

    # name -> Channel
    @channels = {}

    @commands = {
      'alias'  => AliasCommand,
      'help'   => HelpCommand,
      'join'   => JoinCommand,
      'list'   => ListCommand,
      'me'     => MeCommand,
      'part'   => PartCommand,
      'scores' => ScoresCommand,
    }

    @logger = logger ? logger : Logger.new(STDOUT)
    @sender = MessageSender.new(@client, 2, @logger)

    @current_version = 0
    @saved_version = 0

    @state_mutex = Mutex.new
    @current_version_condition = ConditionVariable.new

    @state_file = state_file
    if File.exists?(@state_file)
      @state_mutex.synchronize do
        File.open(@state_file, 'r') do |f|
          deserialize(f) or raise RuntimeError.new(
            "Unable to load state from #@state_file.")
        end
      end
    end

    @save_thread = Thread.new { loop { save_state_when_changed } }
    @save_interval = 10  # Wait at least 10 sec between saving state.
    @last_save_time = 0
  end

  def inc_version
    @current_version += 1
    @current_version_condition.broadcast
  end

  # Look up a user from their JID.  A new User object is created if
  # necessary.
  def get_user(jid)
    # Drop the resource.
    parts = jid.to_s.split('/')
    jid = parts[0]

    user = @users[jid]
    if not user
      user = User.new(@sender, jid)
      @users[jid] = user
    end
    user
  end

  # Look up a channel from its name.  If 'create' is true, the channel will
  # be created if it doesn't exist.
  def get_channel(name, create)
    channel = @channels[name]
    if not channel
      if not create
        return nil
      else
        channel = Channel.new(name)
        @channels[name] = channel
      end
    end
    channel
  end

  # Get the user with the passed-in nickname.
  def get_user_with_nick(nick)
    @users.values.each do |u|
      return u if u.nick == nick
    end
    nil
  end

  # Get the chat system's state as a string that can be restored later.
  def serialize()
    data = {
      'channels' => @channels.values.collect {|c| c.serialize },
      'users' => @users.values.collect {|u| u.serialize },
    }
    data.to_yaml
  end

  # Restore the chat system's state frOm a File object.
  # Returns false on failure.
  def deserialize(file)
    @logger.info("Deserializing #{file.path}")
    yaml = YAML.load(file)
    if not yaml
      @logger.error("Unable to parse #{file.path}")
      return false
    end

    @channels.clear
    yaml['channels'].each do |c|
      channel = Channel.deserialize(self, c)
      @channels[channel.name] = channel
    end

    @users.clear
    yaml['users'].each do |u|
      user = User.deserialize(self, u)
      @users[user.jid] = user
    end

    @logger.info(
      "Loaded #{@channels.size} channel(s) and #{@users.size} user(s)")
    true
  end

  # Block until the state changes (determined by waiting on
  # @current_version_condition) and then write it to disk.
  def save_state_when_changed
    @state_mutex.synchronize do
      loop do
        break if @current_version > @saved_version
        @logger.debug("Waiting for state change at version #@current_version")
        @current_version_condition.wait @state_mutex
      end
    end

    # Wait a bit if we wrote the previous data recently.
    time_to_sleep = [@save_interval - (Time.now.to_f - @last_save_time), 0].max
    @logger.debug("Sleeping #{time_to_sleep} sec before writing state")
    sleep(time_to_sleep)

    # We know that the version's changed, so this should always do a write.
    save_state_if_changed
  end

  # Save the state to disk if it's changed, returning without writing
  # anything if it hasn't.
  def save_state_if_changed
    data = ''
    @state_mutex.synchronize do
      return if @current_version == @saved_version
      data = serialize
      @saved_version = @current_version
      @last_save_time = Time.now.to_f
    end

    @logger.info("Writing state at version #@saved_version to #@state_file")
    tmpfile = @state_file + '.tmp'
    File.open(tmpfile, File::CREAT|File::RDWR) {|f| f.write(data) }
    File.rename(tmpfile, @state_file)
  end

  def handle_presence(presence)
  end

  def handle_subscription_request(item, presence)
    @logger.info("Accepting subscription request from #{presence.from}")
    @roster.accept_subscription(presence.from)
  end

  def handle_message(message)
    return if message.type == :error or not message.body

    user = get_user(message.from.to_s)

    if message.body[0,1] == '/'
      handle_command(user, message.body)
    else
      if user.channel
        user.channel.repeat_message(user, message.body)
        if message.body =~ /\b(\S+)(\+\+|--)($|\s+(.*))/
          if $2 == '++'
            user.channel.increment_score($1, $4)
          else
            user.channel.decrement_score($1, $4)
          end
          @state_mutex.synchronize { inc_version }
        end
      else
        if not user.welcome_sent
          user.send_welcome
        else
          user.enqueue_message('_You need to join a channel first._')
        end
      end
    end
  end

  def handle_command(user, text)
    if not %r!^/([a-z]+)\s*(.*)! =~ text
      user.enqueue_message('_Unparsable command; try */help*._')
      return
    end

    cmd_name, arg = $1, $2
    cmd = @commands[cmd_name]
    if cmd
      cmd.new(self, user, arg).run
    else
      user.enqueue_message("_Unknown command \"#{cmd_name}\"; try */help*._")
    end
  end

  class Command
    def initialize(chat, user, arg)
      @chat = chat
      @user = user
      @arg = arg
    end

    def run
    end

    def status(text)
      @user.enqueue_message('_' + text + '_')
    end

    def Command.usage
      return ['[arg1] [arg2] ...', 'Description of command.']
    end
  end

  class AliasCommand < Command
    def run
      parts = CSV::parse_line(@arg, ' ')
      if parts.size != 1
        status("*/alias* requires 1 argument; got #{parts.size}.")
        return
      end

      nick = parts[0].to_s
      if @user.nick == nick
        status("Your alias is already set to #{nick}.")
        return
      end

      existing_user = @chat.get_user_with_nick(nick)
      if existing_user
        status("Alias \"#{nick}\" already in use by #{existing_user.jid}.")
        return
      end

      old_nick = @user.nick
      success = false
      @chat.state_mutex.synchronize do
        success = @user.change_nick(nick)
        @chat.inc_version if success
      end

      if success
        if @user.channel
          @user.channel.broadcast_message(
            "_*#{old_nick}* (#{@user.jid}) is now known as *#{@user.nick}*._")
        end
      else
        status("Invalid alias \"#{parts[0]}\".")
      end
    end

    def AliasCommand.usage
      return ['[name]', 'Choose a display name.']
    end
  end

  class HelpCommand < Command
    def run
      cmds = @chat.commands.collect do |name, cmd|
        args, desc = cmd.usage
        "*/#{name}#{args ? ' ' + args : ''}* - #{desc}"
      end
      text = cmds.sort.join("\n")
      @user.enqueue_message("Commands:\n#{text}")
    end

    def HelpCommand.usage
      return [nil, 'Display this message.']
    end
  end

  class JoinCommand < Command
    def run
      parts = CSV::parse_line(@arg, ' ')
      if parts.empty? or parts.size > 2
        status("*/join* requires 1 or 2 arguments; got #{parts.size}.")
        return
      end

      name = parts[0].to_s
      password = (parts.size == 2 ? parts[1].to_s : nil)

      channel = @chat.get_channel(name, false)
      if not channel
        @chat.state_mutex.synchronize do
          channel = @chat.get_channel(name, true)
          channel.password = password
          @chat.inc_version
        end
        status("Created \"#{name}\".")
      end

      if channel.password and password != channel.password
        status("Incorrect or missing password for \"#{name}\".")
        return
      end

      if @user.channel == channel
        status("Already a member of \"#{name}\".")
        return
      end

      PartCommand.new(@chat, @user, '').run if @user.channel
      channel.broadcast_message(
        "_*#{@user.nick}* (#{@user.jid}) has joined \"#{channel.name}\"._")
      @chat.state_mutex.synchronize do
        channel.add_user(@user)
        @user.channel = channel
        @chat.inc_version
      end

      status("Joined \"#{name}\" with #{channel.users.size} user" +
             (channel.users.size == 1 ? '' : 's') + ' total.')
    end

    def JoinCommand.usage
      return ['[name] [password]',
              'Join a channel, creating it if it doesn\'t exist. ' +
              'Password is optional.']
    end
  end

  class ListCommand < Command
    def run
      channel = @user.channel
      if not channel
        status('Not currently in a channel.')
        return
      end

      out = "#{channel.users.size} user" +
        (channel.users.size == 1 ? '' : 's') +
        " in \"#{channel.name}\":\n"
      channel.users.each do |u|
        out += "*#{u.nick}* (#{u.jid})\n"
      end

      @user.enqueue_message(out)
    end

    def ListCommand.usage
      return [nil, 'List users in the current channel.']
    end
  end

  class MeCommand < Command
    def run
      text = @arg.strip
      if text.empty?
        status('Expected some descriptive text.')
        return
      end

      if not @user.channel
        status('Not currently in a channel.')
      end

      @user.channel.broadcast_message("_* #{@user.nick} #{text}_")
    end

    def MeCommand.usage
      return ['[description]', 'Announce what you\'re doing.']
    end
  end

  class PartCommand < Command
    def run
      channel = @user.channel
      if not channel
        status('Not currently in a channel.')
        return
      end

      @chat.state_mutex.synchronize do
        channel.remove_user(@user)
        @user.channel = nil
        @chat.inc_version
      end

      status("Left \"#{channel.name}\".")
      channel.broadcast_message(
        "_*#{@user.nick}* (#{@user.jid}) has left #{channel.name}._")
    end

    def PartCommand.usage
      return [nil, 'Leave the current channel.']
    end
  end

  class ScoresCommand < Command
    def run
      if not @user.channel
        status('Not currently in a channel.')
        return
      end

      lines = []
      @user.channel.scores.each do |name, score|
        lines << "*#{name}*: #{score}"
      end
      out = "Scores for \"#{@user.channel.name}\":\n#{lines.join("\n")}"
      @user.enqueue_message(out)
    end

    def ScoresCommand.usage
      return [nil, 'List scores in the current channel.']
    end
  end
end


# Crash if a thread sees an exception.
Thread.abort_on_exception = true

# Create a logger for xmpp4r to use.
jabber_logger = Logger.new('jabber.log')
jabber_logger.level = Logger::DEBUG
Jabber::logger = jabber_logger
Jabber::debug = true

(jid, password) = File.open(AUTH_FILE) {|f| f.readline.split }
chat = SmartyChat.new(jid, password, STATE_FILE, Logger.new('chat.log'))

# Install some signal handlers.
save_and_exit = Proc.new do
  $stderr.print 'Saving state before exiting... '
  chat.save_state_if_changed
  $stderr.puts 'done.'
  Kernel.exit!(0)
end
Kernel.trap('INT', save_and_exit)
Kernel.trap('TERM', save_and_exit)

# Put the main thread in sleep mode (the parser thread will still get
# scheduled).
Thread.stop
