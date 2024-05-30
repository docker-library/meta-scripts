# our old "subset.txt", but inverted
# this way, we can "fail open" correctly (new images should be part of meta by default)
# see "Jenkinsfile.meta" for how/why this turns into "subset.txt"
def repos_anti_subset:
	[
		# as we remove items from this list, we need to be careful that none of their *children* are still in the list
		# (which is why this is sorted in rough "build order" -- that means we can ~safely "pop" off the bottom)

		"almalinux", # direct children: crate
		"alpine", # direct children: amazoncorretto amazonlinux api-firewall arangodb archlinux bash bonita caddy chronograf consul docker eclipse-mosquitto eclipse-temurin eggdrop erlang fluentd golang haproxy haxe httpd influxdb irssi jobber julia kapacitor kong liquibase memcached nats nats-streaming nginx node notary php postgres python rabbitmq rakudo-star redis registry ruby rust spiped teamspeak telegraf traefik varnish vault znc
		"alt",
		"amazonlinux", # direct children: amazoncorretto swift
		"api-firewall",
		"centos", # direct children: eclipse-temurin ibm-semeru-runtimes percona swift
		"clearlinux",
		"clefos",
		"consul",
		"crate",
		"debian", # direct children: adminer aerospike buildpack-deps chronograf clojure couchdb dart emqx erlang haproxy haskell hitch httpd influxdb irssi julia maven memcached mono mysql neo4j neurodebian nginx node odoo openjdk perl php postgres pypy python r-base redis rethinkdb rocket.chat ruby rust spiped swipl unit varnish
		"eclipse-mosquitto",
		"eggdrop",
		"emqx",
		"express-gateway",
		"hitch",
		"jobber",
		"mageia",
		"mono",
		"nats",
		"nats-streaming",
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
		"vault",
		"yourls",
		"znc",
		"adminer",
		"amazoncorretto", # direct children: jetty maven tomcat
		"backdrop",
		"buildpack-deps", # direct children: erlang gcc golang haskell haxe influxdb kapacitor node openjdk perl pypy python rakudo-star ruby rust telegraf
		"composer", # direct children: drupal
		"couchbase",
		"dart",
		"eclipse-temurin", # direct children: cassandra clojure flink gradle groovy jetty jruby lightstreamer liquibase maven neo4j orientdb solr sonarqube spark storm tomcat tomee unit zookeeper
		"friendica",
		"gazebo",
		"haskell",
		"haxe",
		"ibm-semeru-runtimes", # direct children: maven open-liberty tomee websphere-liberty
		"ibmjava", # direct children: maven websphere-liberty
		"jetty", # direct children: geonetwork
		"joomla",
		"kong",
		"lightstreamer",
		"liquibase",
		"matomo",
		"mediawiki",
		"monica",
		"nextcloud",
		"node", # direct children: express-gateway ghost mongo-express unit
		"open-liberty",
		"orientdb",
		"python", # direct children: hylang plone satosa unit
		"rakudo-star",
		"ros",
		"sapmachine", # direct children: maven
		"satosa",
		"silverpeas",
		"spark",
		"swift",
		"tomcat", # direct children: convertigo geonetwork xwiki
		"websphere-liberty",
		"convertigo",
		"geonetwork",
		"maven",
		"plone",

		empty
	]
;

# a helper for "build_should_sbom"
def _sbom_subset:
	[
		# only repositories we have explicitly verified
		"aerospike",
		"arangodb",
		"archlinux",
		"bash",
		"bonita",
		"buildpack-deps",
		"busybox",
		"caddy",
		"cassandra",
		"chronograf",
		"clojure",
		"couchdb",
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
		"influxdb",
		"jruby",
		"julia",
		"kapacitor",
		"kibana",
		"logstash",
		"mariadb",
		"memcached",
		"mongo",
		"mongo-express",
		"mysql",
		"neo4j",
		"neurodebian",
		"nginx",
		"odoo",
		"openjdk",
		"perl",
		"photon",
		"php",
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
		"solr",
		"sonarqube",
		"storm",
		"telegraf",
		"tomcat",
		"tomee",
		"wordpress",
		"xwiki",
		"zookeeper",
		empty
	]
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
