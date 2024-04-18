package main

import (
	"encoding/json"
	"testing"
)

func TestNormalizeInput(t *testing.T) {
	for _, x := range []struct {
		name   string
		raw    string
		normal string
	}{
		{
			"manifest JSON",
			`{
					"type": "manifest",
					"refs": [ "localhost:5000/example:test" ],
					"data": {"mediaType": "application/vnd.oci.image.index.v1+json"}
			}`,
			`{"type":"manifest","refs":["localhost:5000/example:test@sha256:0ae6b7b9d0bc73ee36c1adef005deb431e94cf009c6a947718b31da3d668032d"],"data":"eyJtZWRpYVR5cGUiOiAiYXBwbGljYXRpb24vdm5kLm9jaS5pbWFnZS5pbmRleC52MStqc29uIn0=","copyFrom":null}`,
		},
		{
			"manifest raw",
			`{
					"type": "manifest",
					"refs": [ "localhost:5000/example" ],
					"data": "eyJtZWRpYVR5cGUiOiAiYXBwbGljYXRpb24vdm5kLm9jaS5pbWFnZS5pbmRleC52MStqc29uIn0="
			}`,
			`{"type":"manifest","refs":["localhost:5000/example@sha256:0ae6b7b9d0bc73ee36c1adef005deb431e94cf009c6a947718b31da3d668032d"],"data":"eyJtZWRpYVR5cGUiOiAiYXBwbGljYXRpb24vdm5kLm9jaS5pbWFnZS5pbmRleC52MStqc29uIn0=","copyFrom":null}`,
		},

		{
			"index with children",
			`{
					"type": "manifest",
					"refs": [ "localhost:5000/example:test" ],
					"lookup": { "sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d": "tianon/true" },
					"data": {"mediaType": "application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d","size":1165}],"schemaVersion":2}
			}`,
			`{"type":"manifest","refs":["localhost:5000/example:test@sha256:0cb474919526d040392883b84e5babb65a149cc605b89b117781ab94e88a5e86"],"lookup":{"sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d":"tianon/true"},"data":"eyJtZWRpYVR5cGUiOiAiYXBwbGljYXRpb24vdm5kLm9jaS5pbWFnZS5pbmRleC52MStqc29uIiwibWFuaWZlc3RzIjpbeyJtZWRpYVR5cGUiOiJhcHBsaWNhdGlvbi92bmQub2NpLmltYWdlLm1hbmlmZXN0LnYxK2pzb24iLCJkaWdlc3QiOiJzaGEyNTY6OWVmNDJmMWQ2MDJmYjQyM2ZhZDkzNWFhYzFjYWEwY2ZkYmNlMWFkN2VkY2U2NGQwODBhNGViN2IxM2Y3Y2Q5ZCIsInNpemUiOjExNjV9XSwic2NoZW1hVmVyc2lvbiI6Mn0=","copyFrom":null}`,
		},
		{
			"image",
			`{
					"type": "manifest",
					"refs": [ "localhost:5000/example" ],
					"lookup": { "": "tianon/true" },
					"data": {"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json","config":{"mediaType":"application/vnd.docker.container.image.v1+json","size":1471,"digest":"sha256:690912094c0165c489f874c72cee4ba208c28992c0699fa6e10d8cc59f93fec9"},"layers":[{"mediaType":"application/vnd.docker.image.rootfs.diff.tar.gzip","size":129,"digest":"sha256:4c74d744397d4bcbd3079d9c82a87b80d43da376313772978134d1288f20518c"}]}
			}`,
			`{"type":"manifest","refs":["localhost:5000/example@sha256:1c70f9d471b83100c45d5a218d45bbf7e073e11ea5043758a020379a7c78f878"],"lookup":{"":"tianon/true"},"data":"eyJzY2hlbWFWZXJzaW9uIjoyLCJtZWRpYVR5cGUiOiJhcHBsaWNhdGlvbi92bmQuZG9ja2VyLmRpc3RyaWJ1dGlvbi5tYW5pZmVzdC52Mitqc29uIiwiY29uZmlnIjp7Im1lZGlhVHlwZSI6ImFwcGxpY2F0aW9uL3ZuZC5kb2NrZXIuY29udGFpbmVyLmltYWdlLnYxK2pzb24iLCJzaXplIjoxNDcxLCJkaWdlc3QiOiJzaGEyNTY6NjkwOTEyMDk0YzAxNjVjNDg5Zjg3NGM3MmNlZTRiYTIwOGMyODk5MmMwNjk5ZmE2ZTEwZDhjYzU5ZjkzZmVjOSJ9LCJsYXllcnMiOlt7Im1lZGlhVHlwZSI6ImFwcGxpY2F0aW9uL3ZuZC5kb2NrZXIuaW1hZ2Uucm9vdGZzLmRpZmYudGFyLmd6aXAiLCJzaXplIjoxMjksImRpZ2VzdCI6InNoYTI1Njo0Yzc0ZDc0NDM5N2Q0YmNiZDMwNzlkOWM4MmE4N2I4MGQ0M2RhMzc2MzEzNzcyOTc4MTM0ZDEyODhmMjA1MThjIn1dfQ==","copyFrom":null}`,
		},

		{
			"blob raw",
			`{
				"type": "blob",
				"refs": [ "localhost:5000/example@sha256:1a51828d59323e0e02522c45652b6a7a44a032b464b06d574f067d2358b0e9f1" ],
				"data": "YnVmZnkgdGhlIHZhbXBpcmUgc2xheWVyCg=="
			}`,
			`{"type":"blob","refs":["localhost:5000/example@sha256:1a51828d59323e0e02522c45652b6a7a44a032b464b06d574f067d2358b0e9f1"],"data":"YnVmZnkgdGhlIHZhbXBpcmUgc2xheWVyCg==","copyFrom":null}`,
		},
		{
			"blob json",
			`{
				"type": "blob",
				"refs": [ "localhost:5000/example@sha256:d914176fd50bd7f565700006a31aa97b79d3ad17cee20c8e5ff2061d5cb74817" ],
				"data": {
}
			}`,
			`{"type":"blob","refs":["localhost:5000/example@sha256:d914176fd50bd7f565700006a31aa97b79d3ad17cee20c8e5ff2061d5cb74817"],"data":"ewp9Cg==","copyFrom":null}`,
		},

		{
			"copy manifest (single lookup)",
			`{
				"type": "manifest",
				"refs": [ "localhost:5000/example" ],
				"lookup": { "sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d": "tianon/true" }
			}`,
			`{"type":"manifest","refs":["localhost:5000/example@sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d"],"lookup":{"":"tianon/true","sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d":"tianon/true"},"data":null,"copyFrom":"tianon/true@sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d"}`,
		},
		{
			"copy manifest (fallback lookup)",
			`{
				"type": "manifest",
				"refs": [ "localhost:5000/example" ],
				"lookup": { "": "tianon/true@sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d" }
			}`,
			`{"type":"manifest","refs":["localhost:5000/example@sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d"],"lookup":{"":"tianon/true"},"data":null,"copyFrom":"tianon/true@sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d"}`,
		},
		{
			"copy manifest (ref digest+fallback)",
			`{
				"type": "manifest",
				"refs": [ "localhost:5000/example@sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d" ],
				"lookup": { "": "tianon/true" }
			}`,
			`{"type":"manifest","refs":["localhost:5000/example@sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d"],"lookup":{"":"tianon/true"},"data":null,"copyFrom":"tianon/true@sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d"}`,
		},
		{
			"copy manifest (tag)",
			`{
				"type": "manifest",
				"refs": [ "localhost:5000/example:test" ],
				"lookup": { "": "tianon/true:oci" }
			}`,
			`{"type":"manifest","refs":["localhost:5000/example:test"],"lookup":{"":"tianon/true"},"data":null,"copyFrom":"tianon/true:oci"}`,
		},

		{
			"copy blob (single lookup)",
			`{
				"type": "blob",
				"refs": [ "localhost:5000/example" ],
				"lookup": { "sha256:25be82253336f0b8c4347bc4ecbbcdc85d0e0f118ccf8dc2e119c0a47a0a486e": "tianon/true" }
			}`,
			`{"type":"blob","refs":["localhost:5000/example@sha256:25be82253336f0b8c4347bc4ecbbcdc85d0e0f118ccf8dc2e119c0a47a0a486e"],"lookup":{"":"tianon/true","sha256:25be82253336f0b8c4347bc4ecbbcdc85d0e0f118ccf8dc2e119c0a47a0a486e":"tianon/true"},"data":null,"copyFrom":"tianon/true@sha256:25be82253336f0b8c4347bc4ecbbcdc85d0e0f118ccf8dc2e119c0a47a0a486e"}`,
		},
		{
			"copy blob (fallback lookup)",
			`{
				"type": "blob",
				"refs": [ "localhost:5000/example" ],
				"lookup": { "": "tianon/true@sha256:25be82253336f0b8c4347bc4ecbbcdc85d0e0f118ccf8dc2e119c0a47a0a486e" }
			}`,
			`{"type":"blob","refs":["localhost:5000/example@sha256:25be82253336f0b8c4347bc4ecbbcdc85d0e0f118ccf8dc2e119c0a47a0a486e"],"lookup":{"":"tianon/true"},"data":null,"copyFrom":"tianon/true@sha256:25be82253336f0b8c4347bc4ecbbcdc85d0e0f118ccf8dc2e119c0a47a0a486e"}`,
		},
		{
			"copy blob (ref digest+fallback)",
			`{
				"type": "blob",
				"refs": [ "localhost:5000/example@sha256:25be82253336f0b8c4347bc4ecbbcdc85d0e0f118ccf8dc2e119c0a47a0a486e" ],
				"lookup": { "": "tianon/true" }
			}`,
			`{"type":"blob","refs":["localhost:5000/example@sha256:25be82253336f0b8c4347bc4ecbbcdc85d0e0f118ccf8dc2e119c0a47a0a486e"],"lookup":{"":"tianon/true"},"data":null,"copyFrom":"tianon/true@sha256:25be82253336f0b8c4347bc4ecbbcdc85d0e0f118ccf8dc2e119c0a47a0a486e"}`,
		},

		{
			"multiple refs",
			`{
				"type": "manifest",
				"refs": [
					"localhost:5000/foo@sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d",
					"localhost:5000/bar",
					"localhost:5000/baz@sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d"
				],
				"lookup": { "": "tianon/true" }
			}`,
			`{"type":"manifest","refs":["localhost:5000/foo@sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d","localhost:5000/bar@sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d","localhost:5000/baz@sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d"],"lookup":{"":"tianon/true"},"data":null,"copyFrom":"tianon/true@sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d"}`,
		},
		{
			"multiple refs + multiple lookup (copy)",
			`{
				"type": "manifest",
				"refs": [
					"localhost:5000/foo@sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d",
					"localhost:5000/bar",
					"localhost:5000/baz@sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d"
				],
				"lookup": {
					"sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d": "tianon/true",
					"sha256:25be82253336f0b8c4347bc4ecbbcdc85d0e0f118ccf8dc2e119c0a47a0a486e": "tianon/true"
				}
			}`,
			`{"type":"manifest","refs":["localhost:5000/foo@sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d","localhost:5000/bar@sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d","localhost:5000/baz@sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d"],"lookup":{"":"tianon/true","sha256:25be82253336f0b8c4347bc4ecbbcdc85d0e0f118ccf8dc2e119c0a47a0a486e":"tianon/true","sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d":"tianon/true"},"data":null,"copyFrom":"tianon/true@sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d"}`,
		},
	} {
		x := x // https://github.com/golang/go/issues/60078
		t.Run(x.name, func(t *testing.T) {
			var raw inputRaw
			if err := json.Unmarshal([]byte(x.raw), &raw); err != nil {
				t.Fatalf("JSON parse error: %v", err)
			}
			normal, err := NormalizeInput(raw)
			if err != nil {
				t.Fatalf("normalize error: %v", err)
			}
			if b, err := json.Marshal(normal); err != nil {
				t.Fatalf("JSON generate error: %v", err)
			} else if string(b) != x.normal {
				t.Fatalf("got:\n%s\n\nexpected:\n%s\n", string(b), x.normal)
			}
		})
	}
}
