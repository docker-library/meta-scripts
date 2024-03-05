package registry

const (
	dockerHubCanonical = "docker.io"
	dockerHubConnect   = "registry-1.docker.io" // https://github.com/moby/moby/blob/bf053be997f87af233919a76e6ecbd7d17390e62/registry/config.go#L42
)

var (
	dockerHubHosts = map[string]bool{
		// both dockerHub values above should be listed here (not using variables so this list stays prettier and so we don't miss any if dockerHubConnect changes in the future)
		"":                        true,
		"docker.io":               true,
		"index.docker.io":         true,
		"registry-1.docker.io":    true,
		"registry.hub.docker.com": true,
	}
)

// see also "rate-limits.go" for per-registry rate limits (of which Docker Hub is the primary use case)
