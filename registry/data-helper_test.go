package registry

import (
	"io"
	"testing"

	"cuelabs.dev/go/oci/ociregistry"
	godigest "github.com/opencontainers/go-digest"
)

func TestIsDescriptorDataValid(t *testing.T) {
	t.Parallel()

	data := []byte("buffy the vampire slayer\n")
	validDesc := ociregistry.Descriptor{
		Digest: godigest.FromBytes(data),
		Size:   int64(len(data)),
		Data:   data,
	}

	for _, o := range []struct {
		name string
		desc func() ociregistry.Descriptor
		want bool
	}{
		{"valid", func() ociregistry.Descriptor { return validDesc }, true},
		{"valid sha512", func() ociregistry.Descriptor {
			desc := validDesc
			desc.Digest = godigest.SHA512.FromBytes(data)
			return desc
		}, true},
		{"valid empty", func() ociregistry.Descriptor {
			return ociregistry.Descriptor{
				Digest: godigest.FromBytes(nil),
				Size:   0,
				Data:   []byte{},
			}
		}, true},

		{"nil data", func() ociregistry.Descriptor {
			desc := validDesc
			desc.Data = nil
			return desc
		}, false},
		{"nil data, empty digest", func() ociregistry.Descriptor {
			return ociregistry.Descriptor{
				Digest: godigest.FromBytes(nil),
			}
		}, false},
		{"size too small", func() ociregistry.Descriptor {
			desc := validDesc
			desc.Size--
			return desc
		}, false},
		{"size too big", func() ociregistry.Descriptor {
			desc := validDesc
			desc.Size++
			return desc
		}, false},
		{"wrong digest", func() ociregistry.Descriptor {
			desc := validDesc
			desc.Digest = godigest.FromString("not the right data")
			return desc
		}, false},
		{"data is not the digest", func() ociregistry.Descriptor {
			// the original bug: "Data" interpreted *as* a digest instead of hashing the contents of it
			desc := validDesc
			desc.Data = []byte(validDesc.Digest)
			desc.Size = int64(len(desc.Data))
			return desc
		}, false},
		{"empty digest", func() ociregistry.Descriptor {
			desc := validDesc
			desc.Digest = ""
			return desc
		}, false},
		{"invalid digest syntax", func() ociregistry.Descriptor {
			desc := validDesc
			desc.Digest = "not-a-digest"
			return desc
		}, false},
		{"invalid digest length", func() ociregistry.Descriptor {
			desc := validDesc
			desc.Digest = "sha256:deadbeef"
			return desc
		}, false},
		{"unavailable algorithm", func() ociregistry.Descriptor {
			desc := validDesc
			desc.Digest = "blake3:0000000000000000000000000000000000000000000000000000000000000000"
			return desc
		}, false},
	} {
		o := o // https://github.com/golang/go/issues/60078 (go.mod is still "go 1.21")

		t.Run(o.name, func(t *testing.T) {
			t.Parallel()

			if got := isDescriptorDataValid(o.desc()); got != o.want {
				t.Errorf("isDescriptorDataValid: got %v, want %v", got, o.want)
			}
		})
	}
}

func TestDescriptorDataReader(t *testing.T) {
	t.Parallel()

	data := []byte("buffy the vampire slayer\n")
	desc := ociregistry.Descriptor{
		MediaType: "application/vnd.oci.image.config.v1+json",
		Digest:    godigest.FromBytes(data),
		Size:      int64(len(data)),
		Data:      data,
	}

	t.Run("valid", func(t *testing.T) {
		t.Parallel()

		r := descriptorDataReader(desc)
		if r == nil {
			t.Fatal("unexpected nil reader")
		}
		defer r.Close()

		if got := r.Descriptor(); got.Digest != desc.Digest || got.Size != desc.Size || got.MediaType != desc.MediaType {
			t.Errorf("unexpected descriptor: %+v", got)
		}

		got, err := io.ReadAll(r)
		if err != nil {
			t.Fatal("unexpected error", err)
		}
		if string(got) != string(data) {
			t.Errorf("unexpected data: %q", got)
		}
	})

	t.Run("invalid", func(t *testing.T) {
		t.Parallel()

		bad := desc
		bad.Digest = godigest.FromString("not the right data")

		// explicitly comparing to a literal "nil" (not just "r != nil") to make sure we never hand back a non-nil interface wrapping a nil pointer
		if r := descriptorDataReader(bad); r != nil {
			r.Close()
			t.Fatalf("expected nil reader, got %#v", r)
		}
	})
}
