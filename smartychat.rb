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

  def fullname
    return @jid if @nick == @jid
    "#@nick (#@jid)"
  end

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

  def serialize
    {
      'jid' => @jid,
      'nick' => @nick,
      'channel_name' => (@channel ? @channel.name : nil),
    }
  end

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


class Channel
  attr_reader :name, :users
  attr_accessor :password

  def initialize(name)
    @name = name
    @users = []
    @password = nil
  end

  def add_user(user)
    return if @users.include?(user)
    @users << user
  end

  def remove_user(user)
    return if not @users.include?(user)
    @users.delete(user)
  end

  def repeat_message(sender, body)
    text = "[#{sender.nick}]: #{body}"
    @users.each do |u|
      next if u == sender
      u.enqueue_message(text)
    end
  end

  def broadcast_message(text)
    @users.each {|u| u.enqueue_message(text) }
  end

  def serialize
    {
      'name' => @name,
      'password' => @password,
    }
  end

  def Channel.deserialize(chat, struct)
    channel = Channel.new(struct['name'])
    if struct['password'] and not struct['password'].empty?
      channel.password = struct['password']
    end
    channel
  end
end


class SmartyChat
  attr_reader :state_mutex
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
      'alias' => AliasCommand,
      'help'  => HelpCommand,
      'join'  => JoinCommand,
      'list'  => ListCommand,
      'part'  => PartCommand,
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
        File.open(@state_file, 'r') {|f| deserialize(f) }
      end
    end

    @save_thread = Thread.new { loop { save_state_when_changed } }
  end

  def inc_version
    @current_version += 1
    @current_version_condition.broadcast
  end

  # Look up a user from their JID.  A new User object is created if
  # necessary.
  def get_user(jid)
    user = @users[jid]
    if not user
      user = User.new(@sender, jid)
      @users[jid] = user
    end
    user
  end

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

  def get_user_with_nick(nick)
    @users.values.each do |u|
      return u if u.nick == nick
    end
    return nil
  end

  def serialize()
    data = {
      'channels' => @channels.values.collect {|c| c.serialize },
      'users' => @users.values.collect {|u| u.serialize },
    }
    data.to_yaml
  end

  def deserialize(file)
    @logger.info("Deserializing #{file}")
    yaml = YAML.load(file)
    if not yaml
      @logger.error("Unable to parse #{file}")
      return
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
  end

  def save_state_when_changed
    data = ''
    @state_mutex.synchronize do
      loop do
        break if @current_version > @saved_version
        @logger.debug("Waiting for state change at version #@current_version")
        @current_version_condition.wait @state_mutex
      end

      # TODO: rate-limit?
      data = serialize
      @saved_version = @current_version
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
      else
        if not user.welcome_sent
          user.send_welcome
        else
          user.enqueue_message('_You need to join a channel first_')
        end
      end
    end
  end

  def handle_command(user, text)
    if not %r!^/([a-z]+)\s*(.*)! =~ text
      user.enqueue_message('_Unparsable command; try */help*_')
      return
    end

    cmd_name, arg = $1, $2
    cmd = @commands[cmd_name]
    if cmd
      cmd.new(self, user, arg).run
    else
      user.enqueue_message("_Unknown command \"#{cmd_name}\"; try */help*_")
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
  end

  class AliasCommand < Command
    def run
      parts = CSV::parse_line(@arg, ' ')
      if parts.size != 1
        status("*/alias* requires 1 argument; got #{parts.size}")
        return
      end

      nick = parts[0].to_s
      if @user.nick == nick
        status("Your alias is already set to #{nick}")
        return
      end

      existing_user = @chat.get_user_with_nick(nick)
      if existing_user
        status("Alias \"#{nick}\" already in use by #{existing_user.jid}")
        return
      end

      oldname = @user.fullname
      success = false
      @chat.state_mutex.synchronize do
        success = @user.change_nick(nick)
        @chat.inc_version if success
      end

      if success
        if @user.channel
          @user.channel.broadcast_message("_#{oldname} is now known as #{@user.nick}_")
        end
      else
        status("Invalid alias \"#{parts[0]}\"")
      end
    end
  end

  class HelpCommand < Command
    def run
      @user.enqueue_message('Help isn\'t written yet. :-(')
    end
  end

  class JoinCommand < Command
    def run
      parts = CSV::parse_line(@arg, ' ')
      if parts.empty? or parts.size > 2
        status("*/join* requires 1 or 2 arguments; got #{parts.size}")
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
        status("Created channel #{name}")
      end

      if channel.password and password != channel.password
        status("Incorrect or missing password for channel #{name}")
        return
      end

      if @user.channel == channel
        status("Already a member of channel #{name}")
        return
      end

      PartCommand.new(@chat, @user, '').run if @user.channel
      channel.broadcast_message(
        "_#{@user.fullname} has joined #{channel.name}_")
      @chat.state_mutex.synchronize do
        channel.add_user(@user)
        @user.channel = channel
        @chat.inc_version
      end

      status("Joined channel #{name} with #{channel.users.size} user" +
             (channel.users.size == 1 ? '' : 's'))
    end
  end

  class ListCommand < Command
    def run
      channel = @user.channel
      if not channel
        status("Not currently in a channel")
        return
      end

      out = "#{channel.users.size} user" +
        (channel.users.size == 1 ? '' : 's') +
        " in #{channel.name}:\n"
      channel.users.each do |u|
        out += "* #{u.fullname}\n"
      end

      @user.enqueue_message(out)
    end
  end

  class PartCommand < Command
    def run
      channel = @user.channel
      if not channel
        status("Not currently in a channel")
        return
      end

      @chat.state_mutex.synchronize do
        channel.remove_user(@user)
        @user.channel = nil
        @chat.inc_version
      end

      status("Left channel #{channel.name}")
      channel.broadcast_message(
        "_#{@user.fullname} has left #{channel.name}_")
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

# Put the main thread in sleep mode (the parser thread will still get
# scheduled).
Thread.stop
