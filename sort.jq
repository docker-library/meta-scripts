# input: string
# output: something suitable for use in "sort_by" for sorting in "natural sort" order
def sort_split_natural:
	# https://en.wikipedia.org/wiki/Natural_sort_order
	# similar to https://github.com/tianon/debian-bin/blob/448b5784ac63e6341d5e5762004e3d9e64331cf2/jq/dpkg-version.jq#L3 but a much smaller/simpler problem set (numbers vs non-numbers)
	[
		scan("[0-9]+|[^0-9]+|^$")
		| tonumber? // .
	]
;

# input: ~anything
# output: something suitable for use in "sort_by" for sorting in descending order (for numbers, they become negative, etc)
def sort_split_desc:
	walk(
		if type == "number" then
			-.
		elif type == "string" then
			# https://stackoverflow.com/a/74058663/433558
			[ -explode[], 0 ] # the "0" here helps us with the empty string case; [ "a", "b", "c", "" ]
		elif type == "array" then
			. # TODO sorting an array of arrays where one is empty goes wonky here (for similar reasons to the empty string sorting); [ [1],[2],[3],[0],[] ]
		else
			error("cannot reverse sort type '\(type)': \(.)")
		end
	)
;

# input: key to sort
# output: something suitable for use in "sort_by" for sorting things based on explicit preferences
# top: ordered list of sort preference
# bottom: ordered list of *end* sort preference (ie, what to put at the end, in order)
# [ 1, 2, 3, 4, 5 ] | sort_by(sort_split_pref([ 6, 5, 3 ]; [ 4, 2 ])) => [ 5, 3, 1, 4, 2 ]
def sort_split_pref($top; $bottom):
	. as $o
	| [
		(
			$top
			| index($o) # items in $top get just their index in $top
			// (
				length
				+ (
					$bottom
					| index($o) # items in $bottom get ($top | length) + 1 + index in $bottom
					// -1 # items in neither get ($top | length)
					| . + 1
				)
			)
		),
		$o
	]
;
# a one-argument version of sort_split_pref for the more common usage
def sort_split_pref(top):
	sort_split_pref(top; [])
;
