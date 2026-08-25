#!/bin/bash
set -Eeuo pipefail
umask 077

result=${TKL_TEST_RESULT:?TKL_TEST_RESULT is required}
app_password=${TKL_TEST_APP_PASS:?TKL_TEST_APP_PASS is required}
db_password=${TKL_TEST_DB_PASS:?TKL_TEST_DB_PASS is required}
base=https://localhost
cookie=/tmp/tkl-limesurvey-cookie.$$
page=/tmp/tkl-limesurvey-page.$$
headers=/tmp/tkl-limesurvey-headers.$$
auth=/tmp/tkl-limesurvey-auth.$$
policy=/tmp/tkl-limesurvey-policy.$$

cd /var/www/limesurvey

cleanup() {
    rm -f -- "$cookie" "$page" "$headers" "$auth" "$policy"
}
trap cleanup EXIT

systemctl --quiet is-active apache2.service mariadb.service postfix.service \
    cron.service multi-user.target
systemctl --quiet is-enabled apache2.service mariadb.service postfix.service \
    cron.service
apache2ctl -t
apache2ctl -M 2>/dev/null | grep -q ' rewrite_module '
grep -Fxq 'VERSION_CODENAME=trixie' /etc/os-release
grep -Eq '^turnkey-limesurvey-19\.0' /etc/turnkey_version

installed_version=$(php -r \
    '$config=[]; include $argv[1]; echo $config["versionnumber"];' \
    /var/www/limesurvey/application/config/version.php)
test "$installed_version" = 7.0.11
php_version=$(php --version | head -n1)
[[ $php_version == 'PHP 8.4.'* ]]
dpkg-query -W php8.4-intl mariadb-server adminer \
    webmin-apache webmin-mysql postfix >/dev/null

login_path=/index.php/admin/authentication/sa/login
curl --insecure --fail --silent --show-error \
    --cookie "$cookie" --cookie-jar "$cookie" \
    "$base$login_path" >"$page"
csrf=$(sed -n \
    's/.*value="\([^"]*\)" name="YII_CSRF_TOKEN".*/\1/p' "$page" |
    head -n1)
test -n "$csrf"
curl --insecure --silent --show-error \
    --cookie "$cookie" --cookie-jar "$cookie" \
    --dump-header "$headers" --output "$page" \
    --data-urlencode "YII_CSRF_TOKEN=$csrf" \
    --data-urlencode authMethod=Authdb \
    --data-urlencode user=admin \
    --data-urlencode "password=$app_password" \
    --data-urlencode action=login \
    --data-urlencode login_submit=login \
    "$base$login_path"
grep -q '^HTTP/.* 302' "$headers"
curl --insecure --fail --silent --show-error --location \
    --cookie "$cookie" --cookie-jar "$cookie" \
    "$base/index.php/admin/index" >"$page"
grep -Fq 'Create survey' "$page"
grep -Fq '/index.php/admin/authentication/sa/logout' "$page"
grep -Fq "'localhost'" \
    /var/www/limesurvey/application/config/allowed_hosts.php

auth_payload=$(php -r \
    'echo json_encode(["username"=>"admin", "password"=>$argv[1]]);' \
    "$app_password")
curl --insecure --fail --silent --show-error \
    --header 'Content-Type: application/json' --data "$auth_payload" \
    "$base/rest/v1/auth" >"$auth"
token=$(php -r \
    '$data=json_decode(file_get_contents($argv[1]), true); echo $data["token"] ?? "";' \
    "$auth")
test -n "$token"

survey_id=$(runuser -u www-data -- php \
    /var/www/limesurvey/application/commands/console.php importsurvey \
    /var/www/limesurvey/application/core/plugins/expressionQuestionHelp/sample/limesurvey_survey_expressionQuestionHelp.lss:en)
[[ $survey_id =~ ^[0-9]+$ ]]
curl --insecure --fail --silent --show-error \
    --header "Authorization: Bearer $token" \
    "$base/rest/v1/survey" >"$page"
grep -Fq "\"sid\":$survey_id" "$page"
grep -Fq 'expressionQuestionHelp sample survey' "$page"
MYSQL_PWD=$db_password mariadb --user=root --batch --skip-column-names \
    limesurvey --execute \
    "SELECT surveyls_title FROM lime_surveys_languagesettings WHERE surveyls_survey_id=$survey_id" |
    grep -Fxq 'expressionQuestionHelp sample survey'

systemctl restart mariadb.service
curl --insecure --fail --silent --show-error \
    --header "Authorization: Bearer $token" \
    "$base/rest/v1/survey" >"$page"
grep -Fq "\"sid\":$survey_id" "$page"

curl --insecure --fail --silent --show-error --head \
    https://127.0.0.1:12321/ >/dev/null
curl --insecure --fail --silent --show-error --head \
    https://127.0.0.1:12322/ >/dev/null
ss -ltn | grep -Eq '127\.0\.0\.1:25[[:space:]]'

latest_page=$(curl --fail --silent --show-error \
    https://community.limesurvey.org/downloads/)
grep -Fq 'Community Edition version 7.0.11' <<<"$latest_page"
apt-get update >/dev/null
for package in php8.4 mariadb-server; do
    apt-cache policy "$package" >"$policy"
    installed=$(awk '/Installed:/ {print $2}' "$policy")
    candidate=$(awk '/Candidate:/ {print $2}' "$policy")
    [[ -n $installed && $installed == "$candidate" ]]
done
grep -Rqs '^Suites: trixie' /etc/apt/sources.list.d
! grep -Rqi bookworm /etc/apt/sources.list /etc/apt/sources.list.d

cat >"$result" <<EOF
package_source=Official LimeSurvey Community Edition 7.0.11 complete release archive; PHP 8.4, MariaDB 11.8, Apache, Adminer and Postfix from Debian Trixie
installed_version=LimeSurvey $installed_version; $php_version; mariadb-server $(dpkg-query -W -f='${Version}' mariadb-server)
runtime_checks=normal init; Apache and MariaDB supervision; firstboot administrator web login; REST editor authentication; upstream sample survey import; REST list and direct MariaDB persistence; MariaDB restart; Adminer, Webmin and local Postfix
updater_command=follow the supervised Community Edition upgrade procedure at https://manual.limesurvey.org/Upgrading_from_a_previous_version
updater_result=the official Community Edition download page advertised the installed 7.0.11 release
updater_channel=https://community.limesurvey.org/downloads/ and the official LimeSurvey upgrade procedure
integrity_evidence=the build verified reviewed archive SHA-256 cef826be3e32ae5dd443b1d8f222fc9f3214688115705271c114d4492d7ca9ab; LimeSurvey reported version 7.0.11; APT accepted signed Trixie metadata; no Bookworm source remained
EOF
