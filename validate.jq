# a set of ~generic validation helpers

# usage: validate(.some.value; . >= 123; "must be 123 or bigger")
# will also "nest" sanely: validate(.some; validate(.value; . >= 123; "123+"))
def validate(selector; condition; err):
	# if "selector" contains something like "$foo", "path($foo)" will break, but emit the first few things (so "path(.foo, $foo, .bar)" will emit ["foo"] before the exception is caught on the second round)
	[ try path(selector) catch "BORKBORKBORK" ] as $paths
	| IN($paths[]; "BORKBORKBORK") as $bork
	| (if $bork then [ selector ] else $paths end) as $data
	| reduce $data[] as $maybepath (.;
		(if $bork then $maybepath else getpath($maybepath) end) as $val
		| try (
			if $val | condition then . else
				error("")
			end
		) catch (
			# invalid .["foo"]["bar"]: ERROR MESSAGE HERE
			# value: {"baz":"buzz"}
			error(
				"\ninvalid "
				+ if $bork then
					"value"
				else
					".\($maybepath | map("[\(tojson)]") | add // "")"
				end
				+ ":\n\t\($val | tojson)"
				+ (
					$val
					| err
					| if . and length > 0 then
						"\n\(.)"
					else "" end
				)
				+ (
					ltrimstr("\n")
					| if . and length > 0 then "\n\(.)" else "" end
				)
			)
		)
	)
;
def validate(selector; condition):
	validate(selector; condition; null)
;
def validate(condition):
	validate(.; condition)
;

# usage: validate_IN(.some[].mediaType; "foo/bar", "baz/buzz")
def validate_IN(selector; options):
	validate(selector; IN(options); "valid:\n\t\([ options | tojson ] | join("\n\t"))")
;

# usage: validate_length(.manifests; 1, 2)
def validate_length(selector; lengths):
	validate(selector; IN(length; lengths); "length (\(length)) must be: \([ lengths | tojson ] | join(", "))")
;

# usage: (jq --slurp) validate_one | .some.thing
def validate_one:
	validate_length(.; 1)
	| .[0]
;
