#!/usr/bin/ruby

require 'csv'  # for quoted-string splitting!
require 'thread'
require 'xmpp4r'
require 'xmpp4r/iq'
require 'xmpp4r/message'
require 'xmpp4r/presence'
require 'xmpp4r/roster'
require 'yaml'

AUTHFILE = "#{ENV['HOME']}/.smartychat_auth"

# Crash if a thread sees an exception.
Thread.abort_on_exception = true

Jabber::debug = true


class MessageSender
  def initialize(client, interval_sec=1)
    @client = client
    @interval_sec = interval_sec

    @last_send_time = 0

    # JID -> [msg1, msg2, etc.]
    @queued_messages = {}
    @queued_messages_mutex = Mutex.new
    @queued_messages_condition = ConditionVariable.new

    @thread = Thread.new do
      loop do
        send_queued_messages
      end
    end
  end

  def enqueue_message(jid, text)
    puts "enqueuing message for #{jid}"
    @queued_messages_mutex.synchronize do
      msg_list = @queued_messages[jid]
      if not msg_list
        msg_list = []
        @queued_messages[jid] = msg_list
      end
      msg_list << text
    end

    # Wake up send_queued_messages().
    @queued_messages_condition.broadcast
  end

  def send_queued_messages
    # Wait until there are some queued messages.
    @queued_messages_mutex.synchronize do
      break if not @queued_messages.empty?
      loop do
        puts 'waiting for new messages'
        @queued_messages_condition.wait @queued_messages_mutex
        break if not @queued_messages.empty?
      end
    end

    # Wait a bit if we sent the previous batch recently.
    time_to_sleep = [@interval_sec - (Time.now.to_f - @last_send_time), 0].max
    puts "sleeping #{time_to_sleep} sec before sending messages"
    sleep(time_to_sleep)

    messages = {}
    @queued_messages_mutex.synchronize do
      messages = @queued_messages
      @queued_messages = {}
    end

    messages.each do |jid, list|
      next if list.empty?
      body = list.join("\n")
      msg = Jabber::Message.new(jid, body)
      msg.type = :chat
      @client.send(msg)
    end

    @last_send_time = Time.now.to_f
  end
end


class User
  attr_reader :jid, :nick, :welcome_sent
  attr_accessor :channel

  def initialize(sender, jid, nick=nil)
    @sender = sender
    @jid = jid
    @nick = (nick or jid)
    if @nick == jid and /^([^@]+)/ =~ jid
      @nick = $1
    end
    @channel = nil
    @welcome_sent = false

    @queued_messages = []
    @queued_messages_mutex = Mutex.new
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

  def deserialize(chat, struct)
    @jid = struct['jid']
    @nick = struct['nick']
    @channel = nil
    if struct['channel_name']
      @channel = chat.get_channel(struct['channel_name'], false)
      @channel.add_user(self) if @channel
    end
    @welcome_sent = true
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

  def deserialize(chat, struct)
    @name = struct['name']
    @password = struct['password']
    @users.clear
  end
end


class SmartyChat
  def initialize(jid, password)
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

    @sender = MessageSender.new(@client)
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

  def serialize
    channels = []
    @channels.values.each do |c|
      channels << c.serialize
    end

    users = []
    @users.values.each do |u|
      users << u.serialize
    end
  end

  def handle_presence(presence)
    puts "got presence: #{presence}"
  end

  def handle_subscription_request(item, presence)
    puts "got subscription request from #{presence.from}"
    @roster.accept_subscription(presence.from)
  end

  def handle_message(message)
    puts "got message: #{message}"
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

      existing_user = @chat.get_user_with_nick(parts[0])
      if existing_user
        status("Alias \"#{parts[0]}\" already in use by #{existing_user.jid}")
        return
      end

      oldname = @user.fullname
      if @user.change_nick(parts[0])
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

      name = parts[0]
      password = (parts.size == 2 ? parts[1] : nil)

      channel = @chat.get_channel(name, false)
      if not channel
        channel = @chat.get_channel(name, true)
        channel.password = password
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
      channel.add_user(@user)
      @user.channel = channel

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

      channel.remove_user(@user)
      status("Left channel #{channel.name}")
      channel.broadcast_message(
        "_#{@user.fullname} has left #{channel.name}_")
      @user.channel = nil
    end
  end
end


(jid, password) = File.open(AUTHFILE) {|f| f.readline.split }
chat = SmartyChat.new(jid, password)

# Put the main thread in sleep mode (the parser thread will still get
# scheduled).
Thread.stop
