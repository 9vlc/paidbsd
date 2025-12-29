#!/bin/sh
# go to massivefictions.com for cool books.

_pagename()
{
	local page
	page="${*##*-}"
	page="$(echo "${page%%.*}" | tr '_' ' ')"
	echo "$page"
}

_index()
{
	for page in $(ls pages); do
		page_addr="$page"
		page="$(_pagename "$page")"
		echo "1. [$page](?$page_addr)"
	done
}

#
# main index page
#
if [ "${1:-nul}" = nul ]; then
	echo "!e div block"
	echo "Blog index"
	_index
	echo "!e div block"
	exit 0
else
	echo "!e div iblock"
	echo "[Back to blog index](.)"
	echo "!e div iblock"
fi
echo "!e div block"


blog_file="pages/$(basename "$1")"
if [ ! -f "$blog_file" ]; then
	echo "# The blog you're requesting does not exist"
	echo "file: $blog_file"
	exit 1
else
	echo "!inc $blog_file"
fi
echo "!e div block"
