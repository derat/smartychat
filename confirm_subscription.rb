#!/usr/bin/ruby

require 'xmpp4r'
require 'xmpp4r/presence'
require 'xmpp4r/roster'

AUTH_FILE  = '.smartychat_auth'

if ARGV.size != 1
  $stderr.puts("Usage: #$0 <JID>\n")
  exit 1
end

jabber_logger = Logger.new($stderr)
jabber_logger.level = Logger::DEBUG
Jabber::logger = jabber_logger
Jabber::debug = true

(jid, password) = File.open(AUTH_FILE) {|f| f.readline.split }

client = Jabber::Client.new(Jabber::JID.new(jid))
client.connect
client.auth(password)

#pres = Jabber::Presence.new.set_type(:subscribe).set_priority(-1)
#client.send(pres)

roster = Jabber::Roster::Helper.new(client)
roster.accept_subscription(ARGV[0])

client.close
