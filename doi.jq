# a helper for "build_should_sbom"
def _sbom_subset:
	[
		# only repositories we have explicitly verified
		"aerospike",
		"almalinux",
		"alpine",
		"alt",
		"amazoncorretto",
		"amazonlinux",
		"arangodb",
		"archlinux",
		"backdrop",
		"bash",
		"bonita",
		"buildpack-deps",
		"busybox",
		"caddy",
		"cassandra",
		"chronograf",
		"cirros",
		"clojure",
		"composer",
		"convertigo",
		"couchdb",
		"crate",
		"debian",
		"drupal",
		"eclipse-mosquitto",
		"eclipse-temurin",
		"eggdrop",
		"elasticsearch",
		"elixir",
		"emqx",
		"erlang",
		"fedora",
		"flink",
		"fluentd",
		"gazebo",
		"gcc",
		"geonetwork",
		"ghost",
		"golang",
		"gradle",
		"groovy",
		"haproxy",
		"haskell",
		"hitch",
		"httpd",
		"hylang",
		"ibm-semeru-runtimes",
		"ibmjava",
		"influxdb",
		"irssi",
		"jetty",
		"jruby",
		"julia",
		"kapacitor",
		"kibana",
		"kong",
		"liquibase",
		"logstash",
		"mageia",
		"mariadb",
		"maven",
		"memcached",
		"mongo",
		"mongo-express",
		"mono",
		"mysql",
		"neo4j",
		"neurodebian",
		"nginx",
		"node",
		"odoo",
		"openjdk",
		"open-liberty",
		"oraclelinux",
		"orientdb",
		"perl",
		"photon",
		"php",
		"plone",
		"postgres",
		"pypy",
		"python",
		"r-base",
		"rabbitmq",
		"rakudo-star",
		"redis",
		"registry",
		"rethinkdb",
		"rockylinux",
		"ros",
		"ruby",
		"rust",
		"sapmachine",
		"satosa",
		"silverpeas",
		"solr",
		"sonarqube",
		"spark",
		"spiped",
		"storm",
		"swift",
		"swipl",
		"telegraf",
		"tomcat",
		"tomee",
		"traefik",
		"ubuntu",
		"websphere-liberty",
		"wordpress",
		"xwiki",
		"znc",
		"zookeeper",

		# TODO: add these when PHP extensions and PECL packages are supported in Syft
		# "friendica",
		# "joomla",
		# "matomo",
		# "mediawiki",
		# "monica",
		# "nextcloud",
		# "phpmyadmin",
		# "postfixadmin",
		# "yourls",

		# TODO: add these when the golang dependencies are fixed
		# "api-firewall",
		# "nats",
		# "couchbase",

		# TODO: add these when sbom scanning issues fixed
		# "dart",
		# "clearlinux",
		# "rocket.chat",
		# "teamspeak",
		# "varnish",

		empty
	]
;

# https://github.com/docker-library/meta-scripts/pull/61 (for lack of better documentation for setting this in buildkit)
# https://slsa.dev/provenance/v0.2#builder.id
def buildkit_provenance_builder_id:
	"https://github.com/docker-library"
;

# input: "build" object (with "buildId" top level key)
# output: boolean
def build_should_sbom:
	# see "bashbrew remote arches docker/scout-sbom-indexer:1" (we need the SBOM scanner to be runnable on the host architecture)
	# bashbrew remote arches --json docker/scout-sbom-indexer:1 | jq '.arches | keys_unsorted' -c
	(
		.build.arch as $arch | ["amd64","arm32v5","arm32v7","arm64v8","i386","ppc64le","riscv64","s390x"] | index($arch)
	) and (
		.source.arches[.build.arch].tags
		| map(split(":")[0])
		| unique
		| _sbom_subset as $subset
		| any(.[];
			. as $i
			| $subset
			| index($i)
		)
	)
;

# input: "build" object (with "buildId" top level key)
# output: boolean
def build_should_sign:
	.build.arch == "amd64" and (
		.source.arches[.build.arch].tags
		| map(split(":")[0])
		| unique
		| index("notary")
	)
;
