#!/bin/sh
_pagename()
{
	local page="$*"
	page="${page##*-}"
	page="$(echo "${page%%.*}" | tr '_' ' ')"
	echo "$page"
}

if [ "${1:-nul}" != nul ]; then
	echo "!var title=$(_pagename "$1")"
fi
