package registry_test

import (
	"testing"

	"github.com/docker-library/meta-scripts/registry"
)

func TestParseRefNormalized(t *testing.T) {
	t.Parallel()

	for _, o := range []struct {
		in  string
		out string
	}{
		{"hello-world:latest", "docker.io/library/hello-world:latest"},
		{"tianon/true:oci", "docker.io/tianon/true:oci"},
		{"docker.io/tianon/true:oci", "docker.io/tianon/true:oci"},
		{"localhost:5000/foo", "localhost:5000/foo"},

		// Docker Hub edge cases
		{"hello-world", "docker.io/library/hello-world"},
		{"library/hello-world", "docker.io/library/hello-world"},
		{"docker.io/hello-world", "docker.io/library/hello-world"},
		{"docker.io/library/hello-world", "docker.io/library/hello-world"},
		{"index.docker.io/library/hello-world", "docker.io/library/hello-world"},
		{"registry-1.docker.io/library/hello-world", "docker.io/library/hello-world"},
		{"registry.hub.docker.com/library/hello-world", "docker.io/library/hello-world"},
	} {
		o := o // https://github.com/golang/go/issues/60078
		t.Run(o.in, func(t *testing.T) {
			ref, err := registry.ParseRefNormalized(o.in)
			if err != nil {
				t.Fatal("unexpected error", err)
				return
			}

			out := ref.String()
			if out != o.out {
				t.Fatalf("expected %q, got %q", o.out, out)
				return
			}
		})
	}
}
