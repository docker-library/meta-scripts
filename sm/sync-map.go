package sm

import (
	"sync"
)

// sync.Map, but with generics (and a limited set of methods)
// see also:
// - https://github.com/golang/go/issues/71076
// - https://github.com/golang/go/issues/47657
type Map[K comparable, V any] struct {
	m sync.Map
}

func (m *Map[K, V]) LoadOrStore(key K, value V) (V, bool) {
	actual, loaded := m.m.LoadOrStore(key, value)
	return actual.(V), loaded
}
