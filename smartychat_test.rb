#!/usr/bin/ruby

require 'logger'
require 'smartychat'
require 'test/unit'
require 'xmpp4r'
require 'xmpp4r/presence'

LOG_FILE = 'test.log'

class MockClient
  def initialize
    @message_callback = nil
    @presence_callback = nil
    @sent_messages = []
    @sent_presences = []
    @sent_others = []
  end

  def add_message_callback(&callback)
    @message_callback = callback
  end

  def add_presence_callback(&callback)
    @presence_callback = callback
  end

  def send(stanza)
    if (stanza.class == Jabber::Message)
      @sent_messages << stanza
    elsif (stanza.class == Jabber::Presence)
      @sent_presences << stanza
    else
      @sent_others << stanza
    end
  end

  def shift_presence
    @sent_presences.shift
  end

  def shift_message(to)
    matching_message = nil
    other_messages = []
    @sent_messages.each do |m|
      if not matching_message and m.to == to
        matching_message = m
      else
        other_messages << m
      end
    end
    @sent_messages = other_messages
    matching_message
  end

  def deliver_message(from, body, to='smartychat')
    return if not @message_callback
    msg = Jabber::Message.new(to, body)
    msg.type = :chat
    msg.from = from
    @message_callback.call(msg)
  end
end

class MockRoster
  attr_reader :accepted_subscriptions

  def initialize
    @subscription_request_callback = nil
    @accepted_subscriptions = []
  end

  def add_subscription_request_callback(&callback)
    @subscription_request_callback = callback
  end

  def accept_subscription(from)
    @accepted_subscriptions << from.to_s
  end

  def deliver_subscription_request(from)
    return if not @subscription_request_callback
    presence = Jabber::Presence.new
    presence.type = :subscribe
    presence.from = from
    @subscription_request_callback.call(nil, presence)
  end
end

class TestSmartychat < Test::Unit::TestCase
  def setup
    @client = MockClient.new
    @roster = MockRoster.new
    @chat = SmartyChat.new(
      @client, @roster,
      { :logger => Logger.new(LOG_FILE),
        :message_buffer_sec => 0,
      })
    assert_equal(nil, @client.shift_presence.type)
  end

  # Test that the server accepts subscription requests.
  def test_subscribe
    jid = 'foo@example.com'
    @roster.deliver_subscription_request(jid)
    assert_equal([jid], @roster.accepted_subscriptions)
  end

  # Test a simple chat session.
  def test_basic
    jid1 = 'foo@example.com'
    @client.deliver_message(jid1, '/join #nerds')
    @chat.wait_until_all_messages_sent
    assert_equal('_Created "#nerds"._', @client.shift_message(jid1).body)
    assert_equal('_Joined "#nerds" with 1 user total._',
                 @client.shift_message(jid1).body)
    assert_equal(nil, @client.shift_message(jid1))

    jid2 = 'bar@example.com'
    @client.deliver_message(jid2, '/join #nerds')
    @chat.wait_until_all_messages_sent
    assert_equal('_*bar* <bar@example.com> has joined "#nerds"._',
                 @client.shift_message(jid1).body)
    assert_equal(nil, @client.shift_message(jid1))
    assert_equal('_Joined "#nerds" with 2 users total._',
                 @client.shift_message(jid2).body)
    assert_equal(nil, @client.shift_message(jid2))

    @client.deliver_message(jid1, 'hi bar!')
    @chat.wait_until_all_messages_sent
    assert_equal(nil, @client.shift_message(jid1))
    assert_equal('*foo*: hi bar!', @client.shift_message(jid2).body)
    assert_equal(nil, @client.shift_message(jid2))

    @client.deliver_message(jid2, 'howdy')
    @chat.wait_until_all_messages_sent
    assert_equal('*bar*: howdy', @client.shift_message(jid1).body)
    assert_equal(nil, @client.shift_message(jid1))
    assert_equal(nil, @client.shift_message(jid2))

    @client.deliver_message(jid1, '/part')
    @chat.wait_until_all_messages_sent
    assert_equal('_Left "#nerds"._', @client.shift_message(jid1).body)
    assert_equal(nil, @client.shift_message(jid1))
    assert_equal('_*foo* <foo@example.com> has left "#nerds"._',
                 @client.shift_message(jid2).body)
    assert_equal(nil, @client.shift_message(jid2))
  end

  # Test that password-protected channels work as expected.
  def test_password
    jid1 = 'foo@example.com'
    @client.deliver_message(jid1, '/join #nerds password')
    @chat.wait_until_all_messages_sent
    assert_equal('_Created "#nerds"._', @client.shift_message(jid1).body)
    assert_equal('_Joined "#nerds" with 1 user total._',
                 @client.shift_message(jid1).body)
    assert_equal(nil, @client.shift_message(jid1))

    jid2 = 'bar@example.com'
    @client.deliver_message(jid2, '/join #nerds')
    @chat.wait_until_all_messages_sent
    assert_equal(nil, @client.shift_message(jid1))
    assert_equal('_Incorrect or missing password for "#nerds"._',
                 @client.shift_message(jid2).body)
    assert_equal(nil, @client.shift_message(jid2))

    @client.deliver_message(jid2, '/join #nerds password')
    @chat.wait_until_all_messages_sent
    assert_equal('_*bar* <bar@example.com> has joined "#nerds"._',
                 @client.shift_message(jid1).body)
    assert_equal(nil, @client.shift_message(jid1))
    assert_equal('_Joined "#nerds" with 2 users total._',
                 @client.shift_message(jid2).body)
    assert_equal(nil, @client.shift_message(jid2))
  end
end
