package yam

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"strconv"
)

var errNotFLAC = errors.New("в MP4 не FLAC")

type mp4Box struct {
	typ        string
	start, end int64
	data       int64
}

func readBox(r io.ReaderAt, off, limit int64) (mp4Box, error) {
	var h [16]byte
	if off+8 > limit {
		return mp4Box{}, io.ErrUnexpectedEOF
	}
	if _, err := r.ReadAt(h[:8], off); err != nil {
		return mp4Box{}, err
	}
	size := int64(binary.BigEndian.Uint32(h[:4]))
	hdr := int64(8)
	switch size {
	case 1:
		if _, err := r.ReadAt(h[8:16], off+8); err != nil {
			return mp4Box{}, err
		}
		size = int64(binary.BigEndian.Uint64(h[8:16]))
		hdr = 16
	case 0:
		size = limit - off
	}
	if size < hdr || off+size > limit {
		return mp4Box{}, fmt.Errorf("битый MP4: бокс %q", h[4:8])
	}
	return mp4Box{typ: string(h[4:8]), start: off, data: off + hdr, end: off + size}, nil
}

func listBoxes(r io.ReaderAt, start, end int64) ([]mp4Box, error) {
	var out []mp4Box
	for off := start; off+8 <= end; {
		b, err := readBox(r, off, end)
		if err != nil {
			return out, err
		}
		out = append(out, b)
		off = b.end
	}
	return out, nil
}

func child(r io.ReaderAt, parent mp4Box, path ...string) (mp4Box, bool) {
	cur := parent
	for _, name := range path {
		boxes, _ := listBoxes(r, cur.data, cur.end)
		found := false
		for _, b := range boxes {
			if b.typ == name {
				cur, found = b, true
				break
			}
		}
		if !found {
			return mp4Box{}, false
		}
	}
	return cur, true
}

func payload(buf []byte, b mp4Box) []byte {
	return buf[b.data:b.end]
}

type be []byte

func (b be) u32(o int) uint32 {
	if o+4 > len(b) {
		return 0
	}
	return binary.BigEndian.Uint32(b[o:])
}

func (b be) u64(o int) uint64 {
	if o+8 > len(b) {
		return 0
	}
	return binary.BigEndian.Uint64(b[o:])
}

type segment struct{ off, n int64 }

func addSegment(segs []segment, off, n int64) []segment {
	if n <= 0 {
		return segs
	}
	if k := len(segs) - 1; k >= 0 && segs[k].off+segs[k].n == off {
		segs[k].n += n
		return segs
	}
	return append(segs, segment{off, n})
}

type flacInMP4 struct {
	streamInfo []byte
	segments   []segment
	duration   uint64
	timescale  uint32
}

func parseFlacMP4(r io.ReaderAt, size int64) (*flacInMP4, error) {
	top, err := listBoxes(r, 0, size)
	if err != nil && len(top) == 0 {
		return nil, err
	}
	var moovBox mp4Box
	var moofs []mp4Box
	for _, b := range top {
		switch b.typ {
		case "moov":
			moovBox = b
		case "moof":
			moofs = append(moofs, b)
		}
	}
	if moovBox.typ == "" {
		return nil, errNotFLAC
	}
	if moovBox.end-moovBox.start > 64<<20 {
		return nil, errors.New("слишком большой moov")
	}

	buf := make([]byte, moovBox.end-moovBox.start)
	if _, err := r.ReadAt(buf, moovBox.start); err != nil {
		return nil, err
	}
	mem := bytes.NewReader(buf)
	moov, err := readBox(mem, 0, int64(len(buf)))
	if err != nil {
		return nil, err
	}

	traks, _ := listBoxes(mem, moov.data, moov.end)
	for _, trak := range traks {
		if trak.typ != "trak" {
			continue
		}
		f, trackID, ok := flacTrak(mem, buf, trak)
		if !ok {
			continue
		}
		stbl, _ := child(mem, trak, "mdia", "minf", "stbl")
		f.segments, f.duration = classicSamples(mem, buf, stbl)
		if len(f.segments) == 0 && len(moofs) > 0 {
			defSize, defDur := trexDefaults(mem, buf, moov, trackID)
			f.segments, f.duration, err = fragmentSamples(r, moofs, trackID, defSize, defDur)
			if err != nil {
				return nil, err
			}
		}
		if len(f.segments) == 0 {
			return nil, errors.New("в MP4 нет аудиокадров")
		}
		return f, nil
	}
	return nil, errNotFLAC
}

func flacTrak(mem io.ReaderAt, buf []byte, trak mp4Box) (*flacInMP4, uint32, bool) {
	stsd, ok := child(mem, trak, "mdia", "minf", "stbl", "stsd")
	if !ok {
		return nil, 0, false
	}

	entries, _ := listBoxes(mem, stsd.data+8, stsd.end)
	for _, e := range entries {
		if e.typ != "fLaC" {
			continue
		}

		kids, _ := listBoxes(mem, e.data+28, e.end)
		for _, k := range kids {
			if k.typ != "dfLa" {
				continue
			}
			p := payload(buf, k)

			if len(p) < 4+4+34 || p[4]&0x7f != flacStreamInfo {
				return nil, 0, false
			}
			si := append([]byte(nil), p[4:4+4+34]...)
			f := &flacInMP4{streamInfo: si, timescale: mdhdTimescale(mem, buf, trak)}
			var trackID uint32
			if tkhd, ok := child(mem, trak, "tkhd"); ok {
				p := be(payload(buf, tkhd))
				if len(p) > 0 && p[0] == 1 {
					trackID = p.u32(4 + 16)
				} else {
					trackID = p.u32(4 + 8)
				}
			}
			return f, trackID, true
		}
	}
	return nil, 0, false
}

func mdhdTimescale(mem io.ReaderAt, buf []byte, trak mp4Box) uint32 {
	mdhd, ok := child(mem, trak, "mdia", "mdhd")
	if !ok {
		return 0
	}
	p := be(payload(buf, mdhd))
	if len(p) > 0 && p[0] == 1 {
		return p.u32(4 + 16)
	}
	return p.u32(4 + 8)
}

func classicSamples(mem io.ReaderAt, buf []byte, stbl mp4Box) ([]segment, uint64) {
	stszBox, ok := child(mem, stbl, "stsz")
	if !ok {
		return nil, 0
	}
	stsz := be(payload(buf, stszBox))
	uniform, count := stsz.u32(4), int(stsz.u32(8))
	if count == 0 {
		return nil, 0
	}
	if uniform == 0 && len(stsz) < 12+count*4 {
		return nil, 0
	}
	sampleSize := func(i int) int64 {
		if uniform != 0 {
			return int64(uniform)
		}
		return int64(stsz.u32(12 + i*4))
	}

	var offsets []int64
	if b, ok := child(mem, stbl, "stco"); ok {
		p := be(payload(buf, b))
		n := int(p.u32(4))
		for i := 0; i < n && 8+i*4+4 <= len(p); i++ {
			offsets = append(offsets, int64(p.u32(8+i*4)))
		}
	} else if b, ok := child(mem, stbl, "co64"); ok {
		p := be(payload(buf, b))
		n := int(p.u32(4))
		for i := 0; i < n && 8+i*8+8 <= len(p); i++ {
			offsets = append(offsets, int64(p.u64(8+i*8)))
		}
	}
	stscBox, ok := child(mem, stbl, "stsc")
	if !ok || len(offsets) == 0 {
		return nil, 0
	}
	stsc := be(payload(buf, stscBox))
	entries := int(stsc.u32(4))
	if len(stsc) < 8+entries*12 {
		return nil, 0
	}

	var segs []segment
	sample, e := 0, 0
	for c := 1; c <= len(offsets) && sample < count; c++ {
		for e+1 < entries && int(stsc.u32(8+(e+1)*12)) <= c {
			e++
		}
		perChunk := int(stsc.u32(8 + e*12 + 4))
		off, n := offsets[c-1], int64(0)
		for k := 0; k < perChunk && sample < count; k++ {
			n += sampleSize(sample)
			sample++
		}
		segs = addSegment(segs, off, n)
	}

	var duration uint64
	if b, ok := child(mem, stbl, "stts"); ok {
		p := be(payload(buf, b))
		n := int(p.u32(4))
		for i := 0; i < n && 8+i*8+8 <= len(p); i++ {
			duration += uint64(p.u32(8+i*8)) * uint64(p.u32(8+i*8+4))
		}
	}
	return segs, duration
}

func trexDefaults(mem io.ReaderAt, buf []byte, moov mp4Box, trackID uint32) (size, dur uint32) {
	mvex, ok := child(mem, moov, "mvex")
	if !ok {
		return 0, 0
	}
	boxes, _ := listBoxes(mem, mvex.data, mvex.end)
	for _, b := range boxes {
		if b.typ != "trex" {
			continue
		}
		p := be(payload(buf, b))
		if p.u32(4) == trackID || trackID == 0 {
			return p.u32(16), p.u32(12)
		}
	}
	return 0, 0
}

func fragmentSamples(r io.ReaderAt, moofs []mp4Box, trackID, defSize, defDur uint32) ([]segment, uint64, error) {
	var segs []segment
	var duration uint64
	for _, moof := range moofs {
		if moof.end-moof.start > 16<<20 {
			return nil, 0, errors.New("слишком большой moof")
		}
		buf := make([]byte, moof.end-moof.start)
		if _, err := r.ReadAt(buf, moof.start); err != nil {
			return nil, 0, err
		}
		mem := bytes.NewReader(buf)
		root, err := readBox(mem, 0, int64(len(buf)))
		if err != nil {
			return nil, 0, err
		}
		trafs, _ := listBoxes(mem, root.data, root.end)
		for _, traf := range trafs {
			if traf.typ != "traf" {
				continue
			}
			tfhdBox, ok := child(mem, traf, "tfhd")
			if !ok {
				continue
			}
			h := be(payload(buf, tfhdBox))
			flags := h.u32(0) & 0xffffff
			if id := h.u32(4); trackID != 0 && id != trackID {
				continue
			}
			base := moof.start
			sizeDef, durDef := defSize, defDur
			o := 8
			if flags&0x1 != 0 {
				base = int64(h.u64(o))
				o += 8
			}
			if flags&0x2 != 0 {
				o += 4
			}
			if flags&0x8 != 0 {
				durDef = h.u32(o)
				o += 4
			}
			if flags&0x10 != 0 {
				sizeDef = h.u32(o)
			}

			pos := base
			runs, _ := listBoxes(mem, traf.data, traf.end)
			for _, run := range runs {
				if run.typ != "trun" {
					continue
				}
				t := be(payload(buf, run))
				tf := t.u32(0) & 0xffffff
				n := int(t.u32(4))
				o := 8
				if tf&0x1 != 0 {
					pos = base + int64(int32(t.u32(o)))
					o += 4
				}
				if tf&0x4 != 0 {
					o += 4
				}
				var total int64
				for i := 0; i < n; i++ {
					d, s := durDef, sizeDef
					if tf&0x100 != 0 {
						d = t.u32(o)
						o += 4
					}
					if tf&0x200 != 0 {
						s = t.u32(o)
						o += 4
					}
					if tf&0x400 != 0 {
						o += 4
					}
					if tf&0x800 != 0 {
						o += 4
					}
					if o > len(t) {
						return nil, 0, errors.New("битый trun")
					}
					total += int64(s)
					duration += uint64(d)
				}
				segs = addSegment(segs, pos, total)
				pos += total
			}
		}
	}
	return segs, duration, nil
}

func fixTotalSamples(si []byte, duration uint64, timescale uint32) {
	d := si[4:]
	if len(d) < 18 || duration == 0 || timescale == 0 {
		return
	}
	total := uint64(d[13]&0x0f)<<32 | uint64(binary.BigEndian.Uint32(d[14:18]))
	if total != 0 {
		return
	}
	rate := uint64(d[10])<<12 | uint64(d[11])<<4 | uint64(d[12])>>4
	if rate == 0 {
		return
	}
	total = duration * rate / uint64(timescale)
	d[13] = d[13]&0xf0 | byte(total>>32)&0x0f
	binary.BigEndian.PutUint32(d[14:18], uint32(total))
}

func flacFormat(si []byte) string {
	d := si[4:]
	if len(d) < 18 {
		return "FLAC"
	}
	rate := int(d[10])<<12 | int(d[11])<<4 | int(d[12])>>4
	bits := int(d[12]&1)<<4 | int(d[13])>>4 + 1
	if rate == 0 {
		return "FLAC"
	}
	return fmt.Sprintf("FLAC %d/%s", bits, strconv.FormatFloat(float64(rate)/1000, 'f', -1, 64))
}

func remuxFLAC(r io.ReaderAt, size int64, w io.Writer, t Tags) (string, error) {
	f, err := parseFlacMP4(r, size)
	if err != nil {
		return "", err
	}

	var sync [2]byte
	if _, err := r.ReadAt(sync[:], f.segments[0].off); err != nil {
		return "", err
	}
	if sync[0] != 0xff || sync[1]&0xfe != 0xf8 {
		return "", errNotFLAC
	}
	for _, s := range f.segments {
		if s.off < 0 || s.off+s.n > size {
			return "", errors.New("кадры выходят за пределы файла")
		}
	}

	fixTotalSamples(f.streamInfo, f.duration, f.timescale)
	if _, err := w.Write(flacHeader([][]byte{f.streamInfo}, t)); err != nil {
		return "", err
	}
	cp := make([]byte, 256<<10)
	for _, s := range f.segments {
		if _, err := io.CopyBuffer(w, io.NewSectionReader(r, s.off, s.n), cp); err != nil {
			return "", err
		}
	}
	return flacFormat(f.streamInfo), nil
}

func retagFLAC(r io.ReaderAt, size int64, w io.Writer, t Tags) (string, error) {
	var magic [4]byte
	if _, err := r.ReadAt(magic[:], 0); err != nil || string(magic[:]) != "fLaC" {
		return "", errors.New("не FLAC")
	}
	var keep [][]byte
	pos := int64(4)
	for {
		var h [4]byte
		if _, err := r.ReadAt(h[:], pos); err != nil {
			return "", err
		}
		typ, last := h[0]&0x7f, h[0]&0x80 != 0
		n := int64(h[1])<<16 | int64(h[2])<<8 | int64(h[3])
		if pos+4+n > size {
			return "", errors.New("битые метаданные FLAC")
		}
		if typ != flacVorbis && typ != flacPicture && typ != flacPadding {
			blk := make([]byte, 4+n)
			if _, err := r.ReadAt(blk, pos); err != nil {
				return "", err
			}
			keep = append(keep, blk)
		}
		pos += 4 + n
		if last {
			break
		}
	}
	if len(keep) == 0 || keep[0][0]&0x7f != flacStreamInfo {
		return "", errors.New("нет STREAMINFO")
	}
	if _, err := w.Write(flacHeader(keep, t)); err != nil {
		return "", err
	}
	if _, err := io.CopyBuffer(w, io.NewSectionReader(r, pos, size-pos), make([]byte, 256<<10)); err != nil {
		return "", err
	}
	return flacFormat(keep[0]), nil
}

func tagMP3(r io.ReaderAt, size int64, w io.Writer, t Tags) error {
	head := make([]byte, 10)
	n, _ := r.ReadAt(head, 0)
	skip := id3Size(head[:n])
	if skip > size {
		skip = 0
	}
	if _, err := w.Write(id3Tag(t)); err != nil {
		return err
	}
	_, err := io.CopyBuffer(w, io.NewSectionReader(r, skip, size-skip), make([]byte, 256<<10))
	return err
}
