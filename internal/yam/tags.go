package yam

import (
	"bytes"
	"encoding/binary"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"net/http"
	"strconv"
	"unicode/utf16"
)

type Tags struct {
	Title       string
	Artist      string
	Album       string
	AlbumArtist string
	Genre       string
	Year        int
	Track       int
	TrackTotal  int
	Disc        int
	DiscTotal   int
	Explicit    bool
	Cover       []byte
}

func tagsFor(t Track, cover []byte) Tags {
	return Tags{
		Title:       t.Title,
		Artist:      t.Artists,
		Album:       t.Album,
		AlbumArtist: t.AlbumArtist,
		Genre:       t.Genre,
		Year:        t.Year,
		Track:       t.Number,
		TrackTotal:  t.TrackTotal,
		Disc:        t.Disc,
		DiscTotal:   t.DiscTotal,
		Explicit:    t.Explicit,
		Cover:       cover,
	}
}

func coverMIME(b []byte) string {
	if ct := http.DetectContentType(b); ct == "image/png" {
		return ct
	}
	return "image/jpeg"
}

func itoa(n int) string {
	if n <= 0 {
		return ""
	}
	return strconv.Itoa(n)
}

func pair(n, total int) string {
	if n <= 0 {
		return ""
	}
	if total > 0 {
		return strconv.Itoa(n) + "/" + strconv.Itoa(total)
	}
	return strconv.Itoa(n)
}

func utf16BOM(s string) []byte {
	units := utf16.Encode([]rune(s))
	b := make([]byte, 2, 2+len(units)*2+2)
	b[0], b[1] = 0xff, 0xfe
	for _, u := range units {
		b = append(b, byte(u), byte(u>>8))
	}
	return append(b, 0, 0)
}

func id3Frame(buf *bytes.Buffer, id string, body []byte) {
	buf.WriteString(id)
	_ = binary.Write(buf, binary.BigEndian, uint32(len(body)))
	buf.Write([]byte{0, 0})
	buf.Write(body)
}

func id3Text(buf *bytes.Buffer, id, text string) {
	if text == "" {
		return
	}
	id3Frame(buf, id, append([]byte{0x01}, utf16BOM(text)...))
}

const id3Padding = 1024

func id3Tag(t Tags) []byte {
	var frames bytes.Buffer
	id3Text(&frames, "TIT2", t.Title)
	id3Text(&frames, "TPE1", t.Artist)
	id3Text(&frames, "TALB", t.Album)
	id3Text(&frames, "TPE2", t.AlbumArtist)
	id3Text(&frames, "TCON", t.Genre)
	id3Text(&frames, "TYER", itoa(t.Year))
	id3Text(&frames, "TRCK", pair(t.Track, t.TrackTotal))
	id3Text(&frames, "TPOS", pair(t.Disc, t.DiscTotal))
	if t.Explicit {
		id3Frame(&frames, "TXXX", append(append([]byte{0x01}, utf16BOM("ITUNESADVISORY")...), utf16BOM("1")...))
	}
	if len(t.Cover) > 0 {
		var body bytes.Buffer
		body.WriteByte(0x00)
		body.WriteString(coverMIME(t.Cover))
		body.WriteByte(0)
		body.WriteByte(0x03)
		body.WriteByte(0)
		body.Write(t.Cover)
		id3Frame(&frames, "APIC", body.Bytes())
	}

	size := frames.Len() + id3Padding
	out := make([]byte, 0, 10+size)
	out = append(out, 'I', 'D', '3', 3, 0, 0)

	out = append(out, byte(size>>21&0x7f), byte(size>>14&0x7f), byte(size>>7&0x7f), byte(size&0x7f))
	out = append(out, frames.Bytes()...)
	return append(out, make([]byte, id3Padding)...)
}

func id3Size(head []byte) int64 {
	if len(head) < 10 || string(head[:3]) != "ID3" {
		return 0
	}
	n := int64(head[6]&0x7f)<<21 | int64(head[7]&0x7f)<<14 | int64(head[8]&0x7f)<<7 | int64(head[9]&0x7f)
	size := 10 + n
	if head[5]&0x10 != 0 {
		size += 10
	}
	return size
}

const (
	flacStreamInfo = 0
	flacPadding    = 1
	flacVorbis     = 4
	flacPicture    = 6
)

func flacBlockHeader(typ byte, size int, last bool) []byte {
	if last {
		typ |= 0x80
	}
	return []byte{typ, byte(size >> 16), byte(size >> 8), byte(size)}
}

func vorbisComment(t Tags) []byte {
	var comments [][]byte
	add := func(k, v string) {
		if v != "" {
			comments = append(comments, []byte(k+"="+v))
		}
	}
	add("TITLE", t.Title)
	add("ARTIST", t.Artist)
	add("ALBUM", t.Album)
	add("ALBUMARTIST", t.AlbumArtist)
	add("GENRE", t.Genre)
	add("DATE", itoa(t.Year))
	add("TRACKNUMBER", itoa(t.Track))
	add("TRACKTOTAL", itoa(t.TrackTotal))
	add("DISCNUMBER", itoa(t.Disc))
	add("DISCTOTAL", itoa(t.DiscTotal))
	if t.Explicit {
		add("ITUNESADVISORY", "1")
	}

	const vendor = "YAMP"
	var b bytes.Buffer
	_ = binary.Write(&b, binary.LittleEndian, uint32(len(vendor)))
	b.WriteString(vendor)
	_ = binary.Write(&b, binary.LittleEndian, uint32(len(comments)))
	for _, c := range comments {
		_ = binary.Write(&b, binary.LittleEndian, uint32(len(c)))
		b.Write(c)
	}
	return b.Bytes()
}

func flacPictureBlock(cover []byte) []byte {
	mime := coverMIME(cover)
	var w, h, depth uint32
	if cfg, _, err := image.DecodeConfig(bytes.NewReader(cover)); err == nil {
		w, h, depth = uint32(cfg.Width), uint32(cfg.Height), 24
	}
	var b bytes.Buffer
	for _, v := range []uint32{3, uint32(len(mime))} {
		_ = binary.Write(&b, binary.BigEndian, v)
	}
	b.WriteString(mime)
	for _, v := range []uint32{0, w, h, depth, 0, uint32(len(cover))} {
		_ = binary.Write(&b, binary.BigEndian, v)
	}
	b.Write(cover)
	return b.Bytes()
}

func flacHeader(keep [][]byte, t Tags) []byte {
	type block struct {
		typ  byte
		data []byte
	}
	var blocks []block
	for _, k := range keep {
		blocks = append(blocks, block{k[0] & 0x7f, k[4:]})
	}
	blocks = append(blocks, block{flacVorbis, vorbisComment(t)})
	if len(t.Cover) > 0 && len(t.Cover) < 1<<24-64 {
		blocks = append(blocks, block{flacPicture, flacPictureBlock(t.Cover)})
	}
	blocks = append(blocks, block{flacPadding, make([]byte, 4096)})

	var out bytes.Buffer
	out.WriteString("fLaC")
	for i, b := range blocks {
		out.Write(flacBlockHeader(b.typ, len(b.data), i == len(blocks)-1))
		out.Write(b.data)
	}
	return out.Bytes()
}
