module github.com/docker-library/meta-scripts

go 1.21

require (
	cuelabs.dev/go/oci/ociregistry v0.0.0-20240214163758-5ebe80b0a9a6
	github.com/docker-library/bashbrew v0.1.11
	github.com/opencontainers/go-digest v1.0.0
	github.com/opencontainers/image-spec v1.1.0
	golang.org/x/time v0.5.0
)

require (
	github.com/containerd/containerd v1.6.19 // indirect
	github.com/golang/protobuf v1.5.2 // indirect
	github.com/sirupsen/logrus v1.9.0 // indirect
	golang.org/x/sys v0.13.0 // indirect
	google.golang.org/genproto v0.0.0-20221207170731-23e4bf6bdc37 // indirect
	google.golang.org/grpc v1.51.0 // indirect
	google.golang.org/protobuf v1.28.1 // indirect
)

// https://github.com/cue-labs/oci/pull/29
replace cuelabs.dev/go/oci/ociregistry => github.com/tianon/cuelabs-oci/ociregistry v0.0.0-20240322151419-7d3242933116
