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
    broadcast_message("_#{user.nick} has joined #{name}_")
    @users << user
  end

  def remove_user(user)
    return if not @users.include?(user)
    @users.delete(user)
    broadcast_message("_#{user.nick} has left #{name}_")
  end

  def repeat_message(sender, body)
    text = "[#{sender.nick}]: #{body}"
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
      'help' => HelpCommand.new(self),
      'join' => JoinCommand.new(self),
      'part' => PartCommand.new(self),
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
    return channel
  end

  def handle_presence(presence)
    puts "got presence: #{presence}"
  end

  def handle_subcription_request(item, presence)
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
          user.send_message('You need to join a channel first.')
        end
      end
    end
  end

  def handle_command(user, text)
    if not %r!^/([a-z]+)\s*(.*)! =~ text
      user.send_message('Unparsable command.  Try */help*.')
      return
    end

    cmd_name, arg = $1, $2
    cmd = @commands[cmd_name]
    if cmd
      cmd.run(user, arg)
    else
      user.send_message('Unknown command _#{cmd_name}_.  Try */help*.')
    end
  end

  class Command
    def initialize(chat)
      @chat = chat
    end

    def run(user, arg)
    end

    def error(user, text)
      user.send_message("Error: #{text}")
    end

    def status(user, text)
      user.send_message(text)
    end
  end

  class HelpCommand < Command
    def run(user, arg)
      user.send_message('Help isn\'t written yet. :-(')
    end
  end

  class JoinCommand < Command
    def run(user, arg)
      parts = CSV::parse_line(arg, ' ')
      if parts.empty? or parts.size > 2
        error("*/join* requires 1 or 2 arguments; got #{parts.size}")
        return
      end

      name = parts[0]
      password = (parts.size == 2 ? parts[1] : nil)

      channel = @chat.get_channel(name, false)
      if not channel
        channel = @chat.get_channel(name, true)
        channel.password = password
        status(user, "Created channel _#{name}_")
      end

      if channel.password and password != channel.password
        error(user, "Incorrect or missing password for channel _#{name}_")
        return
      end

      if user.channel == channel
        error(user, "Already a member of channel _#{name}_")
        return
      end

      channel.add_user(user)
      user.channel = channel

      status(user, "Joined channel _#{name}_ with #{channel.users.size} user" +
             (channel.users.size == 1 ? "" : "s"))
    end
  end

  class PartCommand < Command
  end
end


(jid, password) = File.open(AUTHFILE) {|f| f.readline.split }
chat = SmartyChat.new(jid, password)

# Put the main thread in sleep mode (the parser thread will still get
# scheduled).
Thread.stop
