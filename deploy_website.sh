#!/bin/bash
#
# Copyright 2019 Square Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# The website is built using MkDocs with the Material theme.
# https://squidfunk.github.io/mkdocs-material/
# It requires Python 3 to run.
# Install the packages with the following command:
# pip install -r requirements.txt
# Preview the site as you're editing it with:
# mkdocs serve
# It also uses CocoaPods and Sourcedocs to build the Swift docs.
# See .buildscript/build_swift_docs.sh for setup info.
#
# Usage deploy_website.sh SHA_OR_REF_TO_DEPLOY
# Set the DRY_RUN flag to any non-null value to skip the actual deploy.
# A custom username/password can be used to authenticate to the git repo by setting
# the GIT_USERNAME and GIT_PASSWORD environment variables.

# Automatically exit the script on error.
set -e

if [ -z "$WORKFLOW_GOOGLE_ANALYTICS_KEY" ]; then
    echo "Must set WORKFLOW_GOOGLE_ANALYTICS_KEY to deploy." >&2
    exit 1
fi

function getAuthenticatedRepoUrl() {
	if (( $# == 0 )); then echo "Must pass repo name" >&2; exit 1; fi
	repoName="$1"

	# Accept username/password overrides from environment variables for Github Actions.
	if [ -n "$GIT_USERNAME" -a -n "$GIT_PASSWORD" ]; then
		echo "Authenticating as $GIT_USERNAME." >&2
		gitCredentials="$GIT_USERNAME:$GIT_PASSWORD"
		echo "https://${gitCredentials}@github.com/$repoName.git"
	else
		echo "Authenticating as current user." >&2
		echo "git@github.com:$repoName.git"
	fi
}

function buildKotlinDocs() {
	# TODO get deploy ref from caller
	echo "Shallow-cloning ${DEPLOY_REF}…"
	git clone --depth 1 --branch $DEPLOY_REF $(getAuthenticatedRepoUrl "square/workflow") $DIR

	cd kotlin
	./gradlew assemble --build-cache --quiet
	./gradlew siteDokka --build-cache --quiet
}

# TODO once both languages are extract, don't need deploy ref for this repo anymore, and can do
# work inline. Instead, both kotlin and swift deploy refs are needed.
DEPLOY_REF=$1
if [ -z "$DEPLOY_REF" ]; then
	echo "Must pass ref to deploy as first argument." >&2
	exit 1
fi
# Try to cut any extra refs/ prefix off the ref. Needed for Github Actions, which passes
# something like refs/tags/vX.Y.Z, which is not accepted by git clone.
# Note that for pull requests, because Github does a shallow clone, the ref we get won't exist
# and this will fail, but that's ok because in that case the ref is already cloneable.
# In that case, rev-parse will still print the argument to stdout, but we don't care about
# the error message or non-zero exit code.
set +e
DEPLOY_REF=$(git rev-parse --abbrev-ref $DEPLOY_REF 2>/dev/null)
set -e

DIR=mkdocs-clone
SWIFT_DOCS_SCRIPT="$(pwd)/.buildscript/build_swift_docs.sh"

# Delete any existing temporary website clone.
echo "Removing ${DIR}…"
rm -rf $DIR

# Clone the repo into temp folder if we need to deploy a different ref.
# This lets us run the scripts from this working copy even if docs are being built
# for a different ref.
echo "Shallow-cloning ${DEPLOY_REF}…"
git clone --depth 1 --branch $DEPLOY_REF $(getAuthenticatedRepoUrl "square/workflow") $DIR

# Move working directory into temp folder.
pushd $DIR

# Need to use the absolute path for these.
SWIFT_API_DIR="$(pwd)/docs/swift/api"
echo "SWIFT_API_DIR=$SWIFT_API_DIR"

echo "Building Kotlin docs…"
buildKotlinDocs # TODO pass in kotlin-specific deploy ref

# Generate the Swift API docs.
echo "Building Swift docs…"
$SWIFT_DOCS_SCRIPT $SWIFT_API_DIR

# Push the new files up to GitHub.
if [ -n "$DRY_RUN" ]; then
	echo "DRY_RUN enabled, building mkdocs but skipping gh-deploy and push…"
	mkdocs build
else
	echo "Running mkdocs gh-deploy --force…"
	# Build the site and force-push to the gh-pages branch.
	mkdocs gh-deploy --force
fi

# Delete our temp folder.
echo "Deploy finished, cleaning up…"
popd
rm -rf $DIR
