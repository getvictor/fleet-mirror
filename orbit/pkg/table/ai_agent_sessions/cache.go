package ai_agent_sessions

import (
	"os"
	"sync"
	"time"

	"github.com/fleetdm/fleet/v4/orbit/pkg/table/internal/fsutil"
)

// stamp identifies one version of a file; fi is nil when the file was absent.
type stamp struct {
	fi    os.FileInfo
	ctime time.Time
}

func stampOf(path string) stamp {
	f, err := fsutil.OpenRegular(path)
	if err != nil {
		return stamp{}
	}
	defer func() { _ = f.Close() }()
	fi, err := f.Stat()
	if err != nil {
		return stamp{}
	}
	return stamp{fi: fi, ctime: fsutil.ChangeTime(f, fi)}
}

// same reports whether two stamps describe the same file content: size,
// modification time, change time and file identity all match. The change
// time catches a rewrite that set the modification time back, since only the
// kernel sets it.
func (a stamp) same(b stamp) bool {
	if a.fi == nil || b.fi == nil {
		return a.fi == nil && b.fi == nil
	}
	return a.fi.Size() == b.fi.Size() && a.fi.ModTime().Equal(b.fi.ModTime()) &&
		a.ctime.Equal(b.ctime) && os.SameFile(a.fi, b.fi)
}

type cacheEntry struct {
	stamps  []stamp
	session Session
	ok      bool
}

// sessionCache keeps parsed sessions for the orbit process's lifetime, so a
// scheduled query only re-reads transcripts that changed.
type sessionCache struct {
	mu sync.Mutex
	m  map[string]cacheEntry
}

var cache = &sessionCache{m: map[string]cacheEntry{}}

func cacheKey(src *source) string {
	return src.agent.name + "\x00" + src.files[0] + "\x00" + src.id
}

// session returns the source's Session, parsing it unless an unchanged copy
// is cached, and marks its key in seen.
func (c *sessionCache) session(src *source, seen map[string]struct{}) (Session, bool) {
	key := cacheKey(src)
	seen[key] = struct{}{}

	files := append(append([]string{}, src.files...), src.deps...)
	stamps := make([]stamp, len(files))
	for i, p := range files {
		stamps[i] = stampOf(p)
	}

	c.mu.Lock()
	e, hit := c.m[key]
	c.mu.Unlock()
	if hit && len(e.stamps) == len(stamps) {
		for i := range stamps {
			if !e.stamps[i].same(stamps[i]) {
				hit = false
				break
			}
		}
		if hit {
			return e.session, e.ok
		}
	}

	s, ok := parseSession(src)
	c.mu.Lock()
	c.m[key] = cacheEntry{stamps: stamps, session: s, ok: ok}
	c.mu.Unlock()
	return s, ok
}

// evict drops entries for transcripts a complete scan no longer found.
func (c *sessionCache) evict(seen map[string]struct{}) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for k := range c.m {
		if _, ok := seen[k]; !ok {
			delete(c.m, k)
		}
	}
}

// resetState empties the cache and the size budget.
func resetState() {
	cache.mu.Lock()
	cache.m = map[string]cacheEntry{}
	cache.mu.Unlock()
	messageBudget.reset()
}
