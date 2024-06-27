# our old "subset.txt", but inverted
# this way, we can "fail open" correctly (new images should be part of meta by default)
# see "Jenkinsfile.meta" for how/why this turns into "subset.txt"
def repos_anti_subset:
	[
		# as we remove items from this list, we need to be careful that none of their *children* are still in the list
		# (which is why this is sorted in rough "build order" -- that means we can ~safely "pop" off the bottom)

		"alpine", # direct children: amazoncorretto amazonlinux api-firewall arangodb archlinux bash bonita caddy chronograf docker eclipse-mosquitto eclipse-temurin eggdrop erlang fluentd golang haproxy haxe httpd influxdb irssi julia kapacitor kong liquibase memcached nats nats-streaming nginx node notary php postgres python rabbitmq rakudo-star redis registry ruby rust spiped teamspeak telegraf traefik varnish znc
		"alt",
		"amazonlinux", # direct children: amazoncorretto swift
		"api-firewall",
		"centos", # direct children: eclipse-temurin ibm-semeru-runtimes percona swift
		"clearlinux",
		"clefos",
		"debian", # direct children: adminer aerospike buildpack-deps chronograf clojure couchdb dart emqx erlang haproxy haskell hitch httpd influxdb irssi julia maven memcached mono mysql neo4j neurodebian nginx node odoo openjdk perl php postgres pypy python r-base redis rethinkdb rocket.chat ruby rust spiped swipl unit varnish
		"eclipse-mosquitto",
		"eggdrop",
		"emqx",
		"hitch",
		"mageia",
		"nats",
		"oraclelinux", # direct children: mysql openjdk percona
		"percona",
		"php", # direct children: backdrop composer drupal friendica joomla matomo mediawiki monica nextcloud phpmyadmin postfixadmin unit wordpress yourls
		"php-zendserver",
		"phpmyadmin",
		"postfixadmin",
		"rocket.chat",
		"sl",
		"spiped",
		"teamspeak",
		"traefik",
		"ubuntu", # direct children: buildpack-deps couchbase eclipse-temurin elasticsearch gazebo gradle ibmjava ibm-semeru-runtimes kibana kong logstash mariadb mongo neurodebian odoo php-zendserver rabbitmq ros sapmachine silverpeas swift
		"varnish",
		"yourls",
		"znc",
		"adminer",
		"amazoncorretto", # direct children: jetty maven tomcat
		"buildpack-deps", # direct children: erlang gcc golang haskell haxe influxdb kapacitor node openjdk perl pypy python rakudo-star ruby rust telegraf
		"couchbase",
		"dart",
		"eclipse-temurin", # direct children: cassandra clojure flink gradle groovy jetty jruby lightstreamer liquibase maven neo4j orientdb solr sonarqube spark storm tomcat tomee unit zookeeper
		"friendica",
		"gazebo",
		"haskell",
		"haxe",
		"jetty", # direct children: geonetwork
		"joomla",
		"lightstreamer",
		"liquibase",
		"matomo",
		"mediawiki",
		"monica",
		"nextcloud",
		"rakudo-star",
		"ros",
		"silverpeas",
		"spark",
		"swift",
		"tomcat", # direct children: convertigo geonetwork xwiki
		"convertigo",
		"geonetwork",

		empty
	]
;

# a helper for "build_should_sbom"
def _sbom_subset:
	[
		# only repositories we have explicitly verified
		"aerospike",
		"almalinux",
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
		"clojure",
		"composer",
		"couchdb",
		"crate",
		"drupal",
		"eclipse-temurin",
		"elasticsearch",
		"elixir",
		"erlang",
		"fedora",
		"flink",
		"fluentd",
		"gcc",
		"ghost",
		"gradle",
		"groovy",
		"haproxy",
		"httpd",
		"hylang",
		"ibm-semeru-runtimes",
		"ibmjava",
		"influxdb",
		"irssi",
		"jruby",
		"julia",
		"kapacitor",
		"kibana",
		"kong",
		"logstash",
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
		"ruby",
		"rust",
		"sapmachine",
		"satosa",
		"solr",
		"sonarqube",
		"storm",
		"telegraf",
		"tomcat",
		"tomee",
		"websphere-liberty",
		"wordpress",
		"xwiki",
		"zookeeper",
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
	.source.arches[.build.arch].tags
	| map(split(":")[0])
	| unique
	| _sbom_subset as $subset
	| any(.[];
		. as $i
		| $subset
		| index($i)
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
