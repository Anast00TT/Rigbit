class_name RbPngSequence
extends RefCounted
## PNG-секвенция в zip: frame_0000.png, frame_0001.png... (альфа сохраняется).
## Потоково: open() / add(image) / close(), чтобы не держать все кадры в памяти.

var prefix := "frame_"
var digits := 4
var count := 0
var _zip: ZIPPacker


static func frame_name(index: int, pfx := "frame_", ndigits := 4) -> String:
	return "%s%0*d.png" % [pfx, ndigits, index]


func open(path: String) -> Error:
	_zip = ZIPPacker.new()
	_zip.compression_level = 0  # PNG уже сжат
	count = 0
	var err := _zip.open(path)
	if err != OK:
		_zip = null
	return err


func add(img: Image) -> Error:
	if _zip == null:
		return ERR_UNCONFIGURED
	var png := img.save_png_to_buffer()
	if png.is_empty():
		return ERR_INVALID_DATA
	var err := _zip.start_file(frame_name(count, prefix, digits))
	if err != OK:
		return err
	err = _zip.write_file(png)
	_zip.close_file()
	if err == OK:
		count += 1
	return err


func close() -> Error:
	if _zip == null:
		return ERR_UNCONFIGURED
	var err := _zip.close()
	_zip = null
	return err


## Всё разом: массив кадров -> zip.
static func write_zip(path: String, frames: Array) -> Error:
	var s := RbPngSequence.new()
	var err := s.open(path)
	if err != OK:
		return err
	for f: Image in frames:
		err = s.add(f)
		if err != OK:
			s.close()
			return err
	return s.close()
