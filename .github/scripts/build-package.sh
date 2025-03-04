#!/bin/bash
# Syntax: build-package.sh version

# Before running this script, tag a new version:
# $ git tag 1.11-b3
# $ git push origin tags/1.11-b3

shopt -s extglob

URL_REPO=https://github.com/matomo-org/matomo.git

LOCAL_REPO="matomo_last_version_git"
LOCAL_ARCH="archives"

# List of Sub-modules that SHOULD be in the packaged release, eg PiwikTracker|CorePluginName
SUBMODULES_PACKAGED_WITH_CORE='log-analytics|plugins/Morpheus/icons|plugins/TagManager'

# Setting umask so it works for most users, see https://github.com/matomo-org/matomo/issues/3869
umask 0022

function Usage() {
    echo -e "ERROR: This command is missing one or more option. See help below."
    echo -e "$0 version [flavour]"
    echo -e "\t* version: Package version under which you want the archive to be published or path to matomo checkout you want packaged."
    echo -e "\t* flavour: Base name of your archive. Can either be 'matomo' or 'piwik'. If unspecified, both archives are generated."
    # exit with code 1 to indicate an error.
    exit 1
}


# check local environment for all required apps/tools
function checkEnv() {
    if [ ! -x "/usr/bin/curl" ] && [ ! -x "$(which curl)" ]
    then
        die "Cannot find curl"
    fi

    if [ ! -x "/usr/bin/git" ] && [ ! -x "$(which git)" ]
    then
        die "Cannot find git"
    fi

    if [ ! -x "/usr/bin/php" ] && [ ! -x "$(which php)" ]
    then
        die "Cannot find php"
    fi

    if [ ! -x "/usr/bin/gpg" ] && [ ! -x "$(which gpg)" ]
    then
        die "Cannot find gpg"
    fi

    if [ ! -x "/usr/bin/zip" ] && [ ! -x "$(which zip)" ]
    then
        die "Cannot find zip"
    fi

    if [ ! -x "/usr/bin/sha256sum" ] && [ ! -x "$(which sha256sum)" ]
    then
        die "Cannot find sha256sum"
    fi
}

# report error and exit
function die() {
    echo -e "$0: $1"
    exit 2
}

# organize files for packaging
function organizePackage() {

    cd "$CURRENT_DIR/$LOCAL_REPO"

    if [ ! -f "composer.phar" ]
    then
        EXPECTED_SIGNATURE="$(wget -q -O - https://composer.github.io/installer.sig)"
        php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
        ACTUAL_SIGNATURE="$(php -r "echo hash_file('SHA384', 'composer-setup.php');")"

        if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]
        then
            >&2 echo 'ERROR: Invalid installer signature'
            rm composer-setup.php
            exit 1
        fi
        php composer-setup.php --quiet || die "Error installing composer "
        rm composer-setup.php
    fi
    # --ignore-platform-reqs in case the building machine does not have one of the packages required ie. GD required by cpchart
    php composer.phar install --no-dev -o -q --ignore-platform-reqs || die "Error installing composer packages"

    # delete most submodules
    for P in $(git submodule status | egrep -v $SUBMODULES_PACKAGED_WITH_CORE | awk '{print $2}')
    do
        echo "removing $P"
        rm -Rf ./$P
    done

    cp tests/README.md $ARCH_DIR

    $CURRENT_DIR/.github/scripts/clean-build.sh

    SYMLINKS=(`find ./ -type l`)
    if [ ${#SYMLINKS[@]} -gt 0 ]
    then
      echo 'Symlinks detected. Please check if following links should be removed:'
      echo ${SYMLINKS[*]}
      exit 1
    fi

    mkdir tests
    mv $ARCH_DIR/README.md tests/

    # Remove and deactivate the TestRunner plugin in production build
    sed -i '/Plugins\[\] = TestRunner/d' config/global.ini.php
    rm -rf plugins/TestRunner

    cp misc/How\ to\ install\ Matomo.html $ARCH_DIR

    if [ -d "misc/package" ]
    then
        rm -rf misc/package/
    fi

    find ./ -type f -printf '%s ' -exec sha256sum {} \; \
        | grep -v "user/.htaccess" \
        | egrep -v 'manifest.inc.php|vendor/autoload.php|vendor/composer/autoload_real.php' \
        | sed '1,$ s/\([0-9]*\) \([a-z0-9]*\) *\.\/\(.*\)/\t\t"\3" => array("\1", "\2"),/;' \
        | sort \
        | sed '1 s/^/<?php\n\/\/ This file is automatically generated during the Matomo build process \
namespace Piwik;\nclass Manifest {\n\tstatic $files=array(\n/; $ s/$/\n\t);\n}/' \
        > ./config/manifest.inc.php

}

if [ -z "$1" ]; then
    echo "Expected a version number as a parameter"
    Usage "$0"
else
    VERSION="$1"
    MAJOR_VERSION=`echo $VERSION | cut -d'.' -f1`
fi

if [ -z "$2" ]; then
    FLAVOUR="matomo piwik"
    echo "Building 'matomo' and 'piwik' archives"
else
    if [ "$2" != "matomo" ] && [ "$2" != "piwik" ]; then
        Usage "$0"
    else
        FLAVOUR="$2"
        echo "Building '$2' archives"
    fi
fi

# check for local requirements
checkEnv

# this is our current folder
CURRENT_DIR="$(pwd)"

ARCH_DIR="$CURRENT_DIR/$LOCAL_ARCH"

echo "Working directory is '$CURRENT_DIR'..."

echo -e "Going to build Matomo $VERSION (Major version: $MAJOR_VERSION)"

if ! echo "$VERSION" | grep -E 'rc|b|a|alpha|beta|dev|build' -i
then
    if curl --output /dev/null --silent --head --fail "https://builds.matomo.org/matomo-$VERSION.zip"
    then
        echo "--> Error: stable version $VERSION has already been built (not expected). <-- "
    fi
fi

echo -e "Proceeding..."
sleep 2

echo "Starting '$FLAVOUR' build...."

if [ "$VERSION" == "build" ]; then
  rm -rf $LOCAL_REPO
  mkdir $LOCAL_REPO
  cp -pdr !($LOCAL_REPO) $LOCAL_REPO
  cp -r .git $LOCAL_REPO
else
  if [ -d "$LOCAL_REPO" ] ; then
      rm -rf $LOCAL_REPO
  fi

  echo "cloning repository for tag $VERSION..."

  # for this to work 'git-lfs' has to be installed on the local machine
  git clone --config filter.lfs.smudge="git-lfs smudge --skip" --single-branch --branch "$VERSION" "$URL_REPO" "$LOCAL_REPO"

  if [ "$?" -ne "0" ] || [ ! -d "$LOCAL_REPO" ]; then
      die "Error: Failed to clone git repository $URL_REPO, maybe tag $VERSION does not exist"
  fi
fi

mkdir -p "$ARCH_DIR"
cd "$ARCH_DIR" || exit

cd "$CURRENT_DIR" || exit

echo -e "Working in $LOCAL_REPO"
cd "$LOCAL_REPO" || exit

# clone submodules that should be in the release
for P in $(git submodule status | egrep $SUBMODULES_PACKAGED_WITH_CORE | awk '{print $2}')
do
    echo -e "cloning submodule $P"
    git submodule update --init --depth=1 $P
done

echo "Preparing release $VERSION"
echo "Git tag: $(git describe --exact-match --tags HEAD)"
echo "Git path: $CURRENT_DIR/$LOCAL_REPO"
echo "Matomo version in core/Version.php: $(php -r "include_once 'core/Version.php'; echo \Piwik\Version::VERSION;")"

if [ "$VERSION" != "build" ]
then
  [ "$(grep "'$VERSION'" core/Version.php | wc -l)" = "1" ] || die "version $VERSION does not match core/Version.php";
fi

echo "Organizing files and generating manifest file..."
organizePackage

for F in $FLAVOUR; do
    echo "Creating '$F' release package"

    # leave $LOCAL_REPO folder
    cd "$ARCH_DIR" || exit

    echo "copying files to a new directory..."
    [ -d "$F" ] && rm -rf "$F"
    cp -pdr "$CURRENT_DIR/$LOCAL_REPO" "$F"
    cd "$F" || exit

    # leave $F folder
    cd ..

    echo "packaging release..."
    rm "$ARCH_DIR/$F-$VERSION.zip" 2> /dev/null
    zip -9 -r "$ARCH_DIR/$F-$VERSION.zip" "$F" How\ to\ install\ Matomo.html > /dev/null

    if [ "$VERSION" != "build" ]; then
      gpg --armor --detach-sign "$ARCH_DIR/$F-$VERSION.zip" || die "Failed to sign $F-$VERSION.zip"
    fi

    rm "$ARCH_DIR/$F-$VERSION.tar.gz"  2> /dev/null
    tar -czf "$ARCH_DIR/$F-$VERSION.tar.gz" "$F" How\ to\ install\ Matomo.html

    if [ "$VERSION" != "build" ]; then
      gpg --armor --detach-sign "$ARCH_DIR/$F-$VERSION.tar.gz" || die "Failed to sign $F-$VERSION.tar.gz"
    fi

done

if [ "$VERSION" != "build" ]; then
  # Check File signatures are correct
  for ext in zip tar.gz
  do
      for F in $FLAVOUR; do
          gpg --verify $ARCH_DIR/$F-$VERSION.$ext.asc
          if [ "$?" -ne "0" ]; then
              die "Failed to verify signature for $ARCH_DIR/$F-$VERSION.$ext"
          fi
      done
  done
fi
