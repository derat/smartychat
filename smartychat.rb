#!/usr/bin/ruby
# XMPP (Jabber) group chat bot
# Written by Daniel Erat <dan-smartychat@erat.org> on 20090711.
#
# License: "freeware", "public domain", etc.  Do whatever you want with it.
# Don't blame me for anything it does (to the point that that's permitted
# by law). :-P

require 'csv'  # for quoted-string splitting!
require 'logger'
require 'thread'
require 'xmpp4r'
require 'xmpp4r/iq'
require 'xmpp4r/message'
require 'xmpp4r/presence'
require 'xmpp4r/roster'
require 'yaml'

AUTH_FILE  = '.smartychat_auth'
STATE_FILE = '.smartychat_state'


# Queues messages, batching them together per-user before sending.
# This attempts to avoid hitting rate limits.
class MessageSender
  attr_accessor :logger

  # hash args keys:
  #   :interval_sec => 0.5
  #   :logger => nil
  #   :use_separate_messages = false
  def initialize(client, args)
    @client = client
    @interval_sec = args[:interval_sec] ? args[:interval_sec].to_i : 0.5
    @use_separate_messages = args[:use_separate_messages] ? true : false
    @sender_thread_busy = false

    @logger = args[:logger] ? args[:logger] : Logger.new(STDOUT)
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
      @sender_thread_busy = true
    end

    uncondensed_messages = 0
    condensed_messages = 0
    messages.each do |jid, list|
      next if list.empty?
      uncondensed_messages += list.size
      if @use_separate_messages
        list.each do |body|
          send_message(jid, body)
          condensed_messages += 1
        end
      else
        send_message(jid, list.join("\n"))
        condensed_messages += 1
      end
    end

    @logger.debug("Sent #{condensed_messages} message(s) " +
                  "(#{uncondensed_messages} uncondensed)")
    @last_send_time = Time.now.to_f

    @queued_messages_mutex.synchronize do
      @sender_thread_busy = false
      # Wake up wait_until_all_messages_sent().
      @queued_messages_condition.broadcast
    end
  end

  def send_message(jid, body)
    msg = Jabber::Message.new(jid, body)
    msg.type = :chat
    @client.send(msg)
  end
  private :send_message

  def wait_until_all_messages_sent
    @logger.debug('Waiting for all messages to be sent')
    @queued_messages_mutex.synchronize do
      loop do
        break if @queued_messages.empty? and not @sender_thread_busy
        @queued_messages_condition.wait @queued_messages_mutex
      end
    end
    @logger.debug('Done waiting for all messages to be sent')
  end
end


# A single user.  Each JID has a User object associated with it.
class User
  attr_reader :jid, :nick
  attr_accessor :channel, :welcome_sent

  def initialize(sender, jid, nick)
    @sender = sender
    @jid = jid.to_s
    @nick = User.valid_nick?(nick) ? nick.to_s : @jid
    @channel = nil
    @welcome_sent = false
  end

  # Change the user's nick.  Returns false for invalid names.
  def change_nick(new_nick)
    return false if not User.valid_nick?(new_nick)
    @nick = new_nick.to_s
    true
  end

  def User.valid_nick?(proposed_nick)
    proposed_nick.to_s =~ /^[-_.a-zA-Z0-9]+$/ ? true : false
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
    text = "*#{sender.nick}*: #{body}"
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

  # hash args keys:
  #   :state_file => nil
  #   :logger => nil
  #   :message_buffer_sec => 0.5
  #   :use_separate_messages => false
  def initialize(client, roster, args)
    @client = client
    @client.add_message_callback {|m| handle_message(m) }
    @client.add_presence_callback {|p| handle_presence(p) }

    @roster = roster
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
      'reset'  => ResetCommand,
      'scores' => ScoresCommand,
    }

    @line_handlers = [
      PlusPlusHandler,
      VamosQuestionHandler,
    ]

    @logger = args[:logger] ? args[:logger] : Logger.new(STDOUT)
    interval_sec = args[:message_buffer_sec] ? args[:message_buffer_sec] : 0.5
    @sender = MessageSender.new(
      @client,
      { :interval_sec => interval_sec,
        :logger => @logger,
        :use_separate_messages => args[:use_separate_messages],
      })

    @current_version = 0
    @saved_version = 0

    @state_mutex = Mutex.new
    @current_version_condition = ConditionVariable.new

    if args[:state_file]
      @state_file = args[:state_file]
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
  end

  def inc_version
    @current_version += 1
    @logger.debug("Incremented version to #@current_version")
    @current_version_condition.broadcast
  end

  # Look up a user from their JID.  If 'create' is true, the user will be
  # created if they don't exist.
  # necessary.
  def get_user(jid, create)
    # Drop the resource.
    parts = jid.to_s.split('/')
    jid = parts[0]

    user = @users[jid]
    if not user and create
      user = User.new(@sender, jid, invent_nick(jid))
      @users[jid] = user
      @logger.debug("Created user #{user.nick} <#{user.jid}>")
    end
    user
  end

  # Look up a channel from its name.  If 'create' is true, the channel will
  # be created if it doesn't exist.
  def get_channel(name, create)
    channel = @channels[name]
    if not channel and create
      channel = Channel.new(name)
      @channels[name] = channel
      @logger.debug("Created channel #{name}")
    end
    channel
  end

  def delete_channel(name)
    channel = @channels[name]
    return if not channel or not channel.users.empty?
    @channels.delete(name)
    @logger.debug("Deleted channel #{name}")
  end

  # Get the user with the passed-in nickname.
  def get_user_with_nick(nick)
    @users.values.each do |u|
      return u if u.nick == nick
    end
    nil
  end

  # Generate a unique nick based on a JID.
  def invent_nick(jid)
    /^([^@]+)/ =~ jid.to_s
    return jid if not $1 or not User.valid_nick?($1)
    return $1 if not get_user_with_nick($1)
    (2 .. 100).each do |i|
      new_nick = "#{$1}#{i}"
      return new_nick if not get_user_with_nick(new_nick)
    end
    jid
  end

  # Wait until all queued messages are sent.  Useful for testing.
  def wait_until_all_messages_sent
    @sender.wait_until_all_messages_sent
  end

  # Get the chat system's state as a string that can be restored later.
  def serialize()
    data = {
      'channels' => @channels.values.collect {|c| c.serialize },
      'users' => @users.values.collect {|u| u.serialize },
    }
    data.to_yaml
  end

  # Restore the chat system's state from a File object.
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

    @channels.each {|n,ch| @channels.delete(n) if ch.users.empty? }

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
    File.open(tmpfile, File::CREAT|File::EXCL|File::RDWR, 0600) do |f|
      f.write(data)
    end
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

    user = get_user(message.from.to_s, false)
    if not user
      @state_mutex.synchronize do
        user = get_user(message.from.to_s, true)
        inc_version
      end
    end

    if message.body[0,1] == '/'
      handle_command(user, message.body)
    else
      if user.channel
        user.channel.repeat_message(user, message.body)
        @line_handlers.each {|h| h.new(self, user, message.body).run }
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
    if not %r!^/([a-z]+)($|\s+(.*))! =~ text
      user.enqueue_message('_Unparsable command; try */help*._')
      return
    end

    cmd_name = $1
    arg = $3 ? $3.strip : ''

    cmd = @commands[cmd_name]
    if cmd
      cmd.new(self, user, arg).run
    else
      user.enqueue_message("_Unknown command \"#{cmd_name}\"; try */help*._")
    end
  end

  # Base class for things that handle text sent to a channel.
  # TODO: This overlaps with Command.
  class LineHandler
    def initialize(chat, user, text)
      @chat = chat
      @user = user
      @text = text
    end

    def run
    end

    # Helper method for sending an italicized message to the user.
    def status(text)
      @user.enqueue_message('_' + text + '_')
    end
  end

  # Update the score for something in response to a '++' or '--' message.
  class PlusPlusHandler < LineHandler
    def run
      if @text =~ /\b(\S{2,})(\+\+|--)(\s*[.,]?\s+(.*)|\.\s*$|$)/
        if $2 == '++'
          @user.channel.increment_score($1, $4)
        else
          @user.channel.decrement_score($1, $4)
        end
        @chat.state_mutex.synchronize { @chat.inc_version }
      end
    end
  end

  # Scold Julie when she asks, "vamos?".
  class VamosQuestionHandler < LineHandler
    def run
      if @text =~ /\b(¿)?vamos\?\s*$/i
        status('"vamos" is a statement, not a question!')
      end
    end
  end

  # Base class for '/' commands.
  class Command
    def initialize(chat, user, arg)
      @chat = chat
      @user = user
      @arg = arg
    end

    def run
    end

    # Helper method for sending an italicized message to the user.
    def status(text)
      @user.enqueue_message('_' + text + '_')
    end

    # Split the passed-in string into an array of strings, respecting
    # double-quoting.
    def split_args(str)
      # We need to handle empty strings ourselves; CSV.parse_line() will
      # return [nil].
      return [] if not str or str.empty?
      return CSV.parse_line(str, ' ').map {|i| i.to_s }
    end

    def Command.usage
      ['[arg1] [arg2] ...', 'Description of command.']
    end
  end

  class AliasCommand < Command
    def run
      parts = split_args(@arg)
      if parts.size != 1
        status("*/alias* requires 1 argument; got #{parts.size}.")
        return
      end

      nick = parts[0].to_s
      if @user.nick == nick
        status("Your alias is already set to \"#{nick}\".")
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
            "_*#{old_nick}* <#{@user.jid}> is now known as *#{@user.nick}*._")
        end
      else
        status("Invalid alias \"#{parts[0]}\".")
      end
    end

    def AliasCommand.usage
      ['[name]', 'Choose a display name.']
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
      [nil, 'Display this message.']
    end
  end

  class JoinCommand < Command
    def run
      parts = split_args(@arg)
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
        "_*#{@user.nick}* <#{@user.jid}> has joined \"#{channel.name}\"._")
      @chat.state_mutex.synchronize do
        channel.add_user(@user)
        @user.channel = channel
        @chat.inc_version
      end

      status("Joined \"#{name}\" with #{channel.users.size} user" +
             (channel.users.size == 1 ? '' : 's') + ' total.')
    end

    def JoinCommand.usage
      ['[name] [password]',
       "Join a channel, creating it if it doesn't exist. Password is optional."]
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
      channel.users.sort {|a,b| a.nick <=> b.nick }.each do |u|
        out += "*#{u.nick}* <#{u.jid}>\n"
      end

      @user.enqueue_message(out)
    end

    def ListCommand.usage
      [nil, 'List users in the current channel.']
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
      ['[description]', 'Announce what you\'re doing.']
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
        "_*#{@user.nick}* <#{@user.jid}> has left \"#{channel.name}\"._")

      @chat.state_mutex.synchronize do
        if channel.users.empty?
          @chat.delete_channel(channel.name)
          @chat.inc_version
        end
      end
    end

    def PartCommand.usage
      [nil, 'Leave the current channel.']
    end
  end

  class ResetCommand < Command
    def run
      if @arg.empty?
        status('*/reset* requires 1 argument with an optional reason')
        return
      end
      thing, reason = @arg.split(' ', 2)

      if not @user.channel
        status('Not currently in a channel.')
        return
      end

      current_score = @user.channel.scores[thing]
      if not current_score
        status("\"#{thing}\" doesn't have a current score in " +
               "\"#{@user.channel.name}\".")
        return
      elsif current_score == 0
        status(
          "\"#{thing}\"'s score is already 0 in \"#{@user.channel.name}\".")
        return
      end

      @user.channel.scores[thing] = 0
      @chat.state_mutex.synchronize { @chat.inc_version }
      @user.channel.broadcast_message(
        "_*#{@user.nick}* reset #{thing}'s score to 0" +
        (reason ? " (#{reason})" : '') + "._")
    end

    def ResetCommand.usage
      ['[thing] [reason]', 'Reset something\'s score.  Reason is optional.']
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
      [nil, 'List scores in the current channel.']
    end
  end
end


if __FILE__ == $0
  # Crash if a thread sees an exception.
  Thread.abort_on_exception = true

  # Create a logger for xmpp4r to use.
  jabber_logger = Logger.new('jabber.log')
  jabber_logger.level = Logger::DEBUG
  Jabber::logger = jabber_logger
  Jabber::debug = true

  (jid, password) = File.open(AUTH_FILE) {|f| f.readline.split }
  client = Jabber::Client.new(Jabber::JID.new(jid))
  client.connect
  client.auth(password)
  roster = Jabber::Roster::Helper.new(client)
  chat = SmartyChat.new(
    client, roster,
    { :state_file => STATE_FILE,
      :logger => Logger.new('chat.log'),
    })

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
end
