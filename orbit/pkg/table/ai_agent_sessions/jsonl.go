package ai_agent_sessions

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"

	"github.com/fleetdm/fleet/v4/orbit/pkg/table/internal/fsutil"
)

// maxRecordBytes bounds one JSONL record. A larger line is a pasted file or a
// huge tool result; it is skipped rather than buffered.
const maxRecordBytes = 8 << 20

// maxTranscriptBytes bounds how much of one transcript is read. The largest
// real sessions are tens of MB; a sparse multi-GB file is read up to here.
const maxTranscriptBytes = 512 << 20

// scanJSONL hands each non-empty line of a JSON Lines file to fn until fn
// returns false. The file is opened without following links or blocking on a
// FIFO, since users control these paths and the extension runs as root.
func scanJSONL(path string, fn func(line []byte) bool) error {
	f, err := fsutil.OpenRegular(path)
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()

	r := bufio.NewReaderSize(io.LimitReader(f, maxTranscriptBytes), 64<<10)
	for {
		line, readErr := readRecord(r)
		if len(line) > 0 && !fn(line) {
			return nil
		}
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				return nil
			}
			return readErr
		}
	}
}

// readRecord reads one newline-terminated record. Records over
// maxRecordBytes are drained and returned empty.
func readRecord(r *bufio.Reader) ([]byte, error) {
	var (
		buf      []byte
		oversize bool
	)
	for {
		chunk, err := r.ReadSlice('\n')
		if !oversize {
			if len(buf)+len(chunk) > maxRecordBytes {
				oversize = true
				buf = nil
			} else {
				buf = append(buf, chunk...)
			}
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		return bytes.TrimSpace(buf), err
	}
}

// firstRecord decodes the first line of a JSON Lines file into v.
func firstRecord(path string, v any) bool {
	var ok bool
	_ = scanJSONL(path, func(line []byte) bool {
		ok = json.Unmarshal(line, v) == nil
		return false
	})
	return ok
}

// readJSON decodes a whole, bounded JSON file into v.
func readJSON(path string, v any) bool {
	b, err := fsutil.ReadFileBounded(path)
	if err != nil {
		return false
	}
	return json.Unmarshal(b, v) == nil
}

// presence records whether a JSON key was present with a non-null value,
// without keeping the value. It is used for secrets whose existence is the
// only thing we need.
type presence bool

func (p *presence) UnmarshalJSON(b []byte) error {
	*p = presence(string(bytes.TrimSpace(b)) != "null")
	return nil
}
