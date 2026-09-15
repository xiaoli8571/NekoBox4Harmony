#!/usr/bin/env bash

set -e -o pipefail

function remove_unused() {
  git rm -rf --ignore-unmatch \
    .github \
    **/*_test.go \
    tstest/ \
    release/ \
    cmd/ \
    util/winutil/s4u/ \
    k8s-operator/ \
    ssh/ \
    wf/ \
    internal/tooldeps \
    gokrazy/ \
    ipn/lapitest \
    ipn/ipnlocal/ipnlocaltest \
    feature/taildrop \
    feature/condregister/maybe_taildrop.go \
    feature/ssh \
    feature/tailnetlock \
    feature/condregister/maybe_tailnetlock.go \
    tool/updateflakes \
    tsconsensus/ \
    tsnet/example
}

remove_unused
remove_unused

go mod tidy
git commit -a -m "Remove unused"
