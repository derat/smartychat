#!/usr/bin/ruby

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
  attr_reader :jid, :nick, :channel, :welcome_sent

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
  def initialize(client, name)
    @client = client
    @name = name
    @users = []
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
          user.send_message("You need to join a channel first.")
        end
      end
    end
  end

  def handle_command(user, command)
  end
end


(jid, password) = File.open(AUTHFILE) {|f| f.readline.split }
chat = SmartyChat.new(jid, password)

# Put the main thread in sleep mode (the parser thread will still get
# scheduled).
Thread.stop
