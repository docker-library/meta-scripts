# our old "subset.txt", but inverted
# this way, we can "fail open" correctly (new images should be part of meta by default)
# see "Jenkinsfile.meta" for how/why this turns into "subset.txt"
def repos_anti_subset:
	[
		# as we remove items from this list, we need to be careful that none of their *children* are still in the list
		# (which is why this is sorted in rough "build order" -- that means we can ~safely "pop" off the bottom)

		"alpine", # direct children: amazoncorretto amazonlinux api-firewall arangodb archlinux bash bonita caddy chronograf docker eclipse-mosquitto eclipse-temurin eggdrop erlang fluentd golang haproxy haxe httpd influxdb irssi julia kapacitor kong liquibase memcached nats nats-streaming nginx node notary php postgres python rabbitmq rakudo-star redis registry ruby rust spiped teamspeak telegraf traefik varnish znc
		"api-firewall",
		"clearlinux",
		"debian", # direct children: aerospike buildpack-deps chronograf clojure couchdb dart emqx erlang haproxy haskell hitch httpd influxdb irssi julia maven memcached mono mysql neo4j neurodebian nginx node odoo openjdk perl php postgres pypy python r-base redis rethinkdb rocket.chat ruby rust spiped swipl unit varnish
		"nats",
		"php", # direct children: backdrop composer drupal friendica joomla matomo mediawiki monica nextcloud phpmyadmin postfixadmin unit wordpress yourls
		"phpmyadmin",
		"postfixadmin",
		"rocket.chat",
		"teamspeak",
		"ubuntu", # direct children: buildpack-deps couchbase eclipse-temurin elasticsearch gazebo gradle ibmjava ibm-semeru-runtimes kibana kong logstash mariadb mongo neurodebian odoo rabbitmq ros sapmachine silverpeas swift
		"varnish",
		"yourls",
		"buildpack-deps", # direct children: erlang gcc golang haskell haxe influxdb kapacitor node openjdk perl pypy python rakudo-star ruby rust telegraf
		"couchbase",
		"dart",
		"eclipse-temurin", # direct children: cassandra clojure flink gradle groovy jetty jruby lightstreamer liquibase maven neo4j orientdb solr sonarqube spark storm tomcat tomee unit zookeeper
		"friendica",
		"haskell",
		"joomla",
		"liquibase",
		"matomo",
		"mediawiki",
		"monica",
		"nextcloud",
		"rakudo-star",
		"silverpeas",

		empty
	]
;

# a helper for "build_should_sbom"
def _sbom_subset:
	[
		# only repositories we have explicitly verified
		"aerospike",
		"almalinux",
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
		"redis",
		"registry",
		"rethinkdb",
		"rockylinux",
		"ros",
		"ruby",
		"rust",
		"sapmachine",
		"satosa",
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
		"websphere-liberty",
		"wordpress",
		"xwiki",
		"znc",
		"zookeeper",
		empty
	]
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
