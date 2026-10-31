package sm_test

import (
	"sync"
	"sync/atomic"
	"testing"

	"github.com/docker-library/meta-scripts/sm"
)

func TestMapLoadOrStore(t *testing.T) {
	t.Parallel()

	var m sm.Map[string, int]

	if v, loaded := m.LoadOrStore("a", 1); loaded || v != 1 {
		t.Errorf("first store: got (%d, %v), want (1, false)", v, loaded)
	}
	if v, loaded := m.LoadOrStore("a", 2); !loaded || v != 1 {
		t.Errorf("second store: got (%d, %v), want (1, true)", v, loaded)
	}
	if v, loaded := m.LoadOrStore("b", 3); loaded || v != 3 {
		t.Errorf("different key: got (%d, %v), want (3, false)", v, loaded)
	}
}

func TestMapLoadOrStorePointer(t *testing.T) {
	t.Parallel()

	var m sm.Map[string, *sync.Mutex]

	first := &sync.Mutex{}
	if v, loaded := m.LoadOrStore("a", first); loaded || v != first {
		t.Errorf("first store: got (%p, %v), want (%p, false)", v, loaded, first)
	}
	if v, loaded := m.LoadOrStore("a", &sync.Mutex{}); !loaded || v != first {
		t.Errorf("second store: got (%p, %v), want (%p, true)", v, loaded, first)
	}
}

func TestMapLoadOrStoreConcurrent(t *testing.T) {
	t.Parallel()

	const goroutines = 100

	var (
		m      sm.Map[string, int]
		wg     sync.WaitGroup
		stored atomic.Int32
		values [goroutines]int
	)
	for i := 0; i < goroutines; i++ {
		i := i // https://github.com/golang/go/issues/60078 (go.mod is still "go 1.21")
		wg.Add(1)
		go func() {
			defer wg.Done()

			v, loaded := m.LoadOrStore("a", i)
			if !loaded {
				stored.Add(1)
			}
			values[i] = v
		}()
	}
	wg.Wait()

	if got := stored.Load(); got != 1 {
		t.Errorf("expected exactly one goroutine to store, got %d", got)
	}
	for i, v := range values {
		if v != values[0] {
			t.Errorf("goroutine %d saw %d, but goroutine 0 saw %d", i, v, values[0])
		}
	}
}
