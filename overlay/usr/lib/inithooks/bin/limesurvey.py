#!/usr/bin/python
"""Set LimeSurvey admin password and email

Option:
    --pass=     unless provided, will ask interactively
    --email=    unless provided, will ask interactively

"""

import sys
import getopt
import hashlib

from dialog_wrapper import Dialog
from mysqlconf import MySQL

def usage(s=None):
    if s:
        print >> sys.stderr, "Error:", s
    print >> sys.stderr, "Syntax: %s [options]" % sys.argv[0]
    print >> sys.stderr, __doc__
    sys.exit(1)

def main():
    try:
        opts, args = getopt.gnu_getopt(sys.argv[1:], "h",
                                       ['help', 'pass=', 'email='])
    except getopt.GetoptError, e:
        usage(e)

    password = ""
    email = ""
    for opt, val in opts:
        if opt in ('-h', '--help'):
            usage()
        elif opt == '--pass':
            password = val
        elif opt == '--email':
            email = val

    if not password:
        d = Dialog('TurnKey Linux - First boot configuration')
        password = d.get_password(
            "LimeSurvey Password",
            "Enter new password for the LimeSurvey 'admin' account.")

    if not email:
        if 'd' not in locals():
            d = Dialog('TurnKey Linux - First boot configuration')

        email = d.get_email(
            "LimeSurvey Email",
            "Enter email address for the LimeSurvey 'admin' account.",
            "admin@example.com")

    hashpass = hashlib.sha256(password).hexdigest()

    m = MySQL()
    m.execute('UPDATE limesurvey.users SET email=\"%s\" WHERE users_name=\"admin\";' % email)
    m.execute('UPDATE limesurvey.users SET password=\"%s\" WHERE users_name=\"admin\";' % hashpass)

    # these settings don't exist until first login and browsing
    # just delete and recreate (supports re-initialization)
    m.execute('DELETE FROM limesurvey.settings_global WHERE stg_name=\"siteadminemail\";')
    m.execute('DELETE FROM limesurvey.settings_global WHERE stg_name=\"siteadminbounce\";')
    m.execute('INSERT INTO limesurvey.settings_global SET stg_name=\"siteadminemail\", stg_value=\"%s\";' % email)
    m.execute('INSERT INTO limesurvey.settings_global SET stg_name=\"siteadminbounce\", stg_value=\"%s\";' % email)

if __name__ == "__main__":
    main()

