#!/usr/bin/ruby

require 'csv'  # for quoted-string splitting!
require 'thread'
require 'xmpp4r'
require 'xmpp4r/iq'
require 'xmpp4r/message'
require 'xmpp4r/presence'
require 'xmpp4r/roster'

AUTHFILE = "#{ENV['HOME']}/.smartychat_auth"

# Crash if a thread sees an exception.
Thread.abort_on_exception = true

Jabber::debug = true


class User
  attr_reader :jid, :nick, :welcome_sent
  attr_accessor :channel

  def initialize(client, jid, nick=nil)
    @client = client
    @jid = jid
    @nick = (nick or jid)
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

  def send_message(body)
    msg = Jabber::Message.new(@jid, body)
    msg.type = :chat
    @client.send(msg)
  end

  def send_welcome
    usage =
      "Welcome to SmartyChat!  You'll need to join a channel using " +
      "*/join* before you can start chatting."
    send_message(usage)
    send_message("Send */help* if you're stuck.")
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
    text = "_#{sender.nick}:_ #{body}"
    @users.each do |u|
      next if u == sender
      u.send_message(text)
    end
  end

  def broadcast_message(text)
    @users.each {|u| u.send_message(text) }
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
  end

  # Look up a user from their JID.  A new User object is created if
  # necessary.
  def get_user(jid)
    user = @users[jid]
    if not user
      user = User.new(@client, jid)
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

  def handle_presence(presence)
    puts "got presence: #{presence}"
  end

  def handle_subscription_request(item, presence)
    puts "got subscription request from #{presence.from}"
    @roster.accept_subscription(presence.from)
  end

  def handle_message(message)
    puts "got message: #{message}"
    return if message.type == :error

    user = get_user(message.from)

    if message.body[0,1] == '/'
      handle_command(user, message.body)
    else
      if user.channel
        user.channel.repeat_message(user, message.body)
      else
        if not user.welcome_sent
          user.send_welcome
        else
          user.send_message('_You need to join a channel first_')
        end
      end
    end
  end

  def handle_command(user, text)
    if not %r!^/([a-z]+)\s*(.*)! =~ text
      user.send_message('_Unparsable command; try */help*_')
      return
    end

    cmd_name, arg = $1, $2
    cmd = @commands[cmd_name]
    if cmd
      cmd.new(self, user, arg).run
    else
      user.send_message("_Unknown command \"#{cmd_name}\"; try */help*_")
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
      @user.send_message('_' + text + '_')
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
      @user.send_message('Help isn\'t written yet. :-(')
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

      @user.send_message(out)
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
