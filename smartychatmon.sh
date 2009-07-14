#!/bin/bash

EMAIL=dan@erat.org
NAME=smartychat.rb
FILE=$HOME/smartychat/.smartychat_alert
REPEAT_MINUTES=360

if ! ps wwaux | grep -v grep | fgrep -q "$NAME"; then
  if ! test -e "$(find $FILE -mmin -${REPEAT_MINUTES} 2>/dev/null)"; then
    /bin/mail -s 'smartychat is down!' $EMAIL <<EOF
Like the subject says, smartychat is down.  Vamoses may
be forfeited; b-nights may end disastrously.  Fix it!
EOF
    touch $FILE
  fi
else
  rm -f $FILE
fi
