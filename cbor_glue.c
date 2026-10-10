// JSON <-> CBOR conversion for the smithy-rpc-v2-cbor protocol.
//
// Compiled at runtime by jitc (see ::aws::_cbor_init in aws.tcl) against the
// rl_json and cbor packages, the first time a cbor-protocol service is used.
//
// encode: the request body is assembled as an rl_json value exactly as for the
// json protocols (template, transforms, null stripping), then converted to CBOR
// guided by the service's shape table, which supplies what JSON can't say: which
// strings are blobs (base64 in the JSON, byte strings on the wire), which
// numbers are timestamps (tag 1) and which are floats.  Values with no shape
// (documents, unmodeled keys) get the RFC 8949 section 6.2 JSON -> CBOR mapping.
//
// decode: responses are converted to the rl_json value the json protocols
// would have returned: byte strings -> base64 strings, tag 1 timestamps -> epoch
// numbers, NaN / Infinity -> the strings Smithy's JSON protocols use.
//
// Shape table: a dict of shape name -> descriptor, where a descriptor is one of
//   s | i | d | b | x | t | D        string, integer, float, boolean, blob,
//                                    timestamp, document (generic)
//   S {wirekey shapename ...}        structure / union
//   L shapename                      list
//   M shapename                      map (string keys)

#include <string.h>
#include <math.h>
#include <inttypes.h>

enum {MAX_DEPTH = 200};

// base64 <<<
static const char b64_alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static Tcl_Obj* b64_encode(const uint8_t* bytes, size_t len) //<<<
{
	const size_t	outlen = 4 * ((len + 2) / 3);
	char*			out = ckalloc(outlen + 1);
	size_t			o = 0;
	defer { ckfree(out); }

	for (size_t i=0; i<len; i+=3) {
		const uint32_t	n = (uint32_t)bytes[i] << 16
			| (i+1 < len ? (uint32_t)bytes[i+1] << 8 : 0)
			| (i+2 < len ? (uint32_t)bytes[i+2] : 0);
		out[o++] = b64_alphabet[(n >> 18) & 63];
		out[o++] = b64_alphabet[(n >> 12) & 63];
		out[o++] = i+1 < len ? b64_alphabet[(n >> 6) & 63] : '=';
		out[o++] = i+2 < len ? b64_alphabet[n & 63] : '=';
	}
	return Tcl_NewStringObj(out, (Tcl_Size)o);
}

//>>>
static int b64_value(char c) //<<<
{
	if (c >= 'A' && c <= 'Z') return c - 'A';
	if (c >= 'a' && c <= 'z') return c - 'a' + 26;
	if (c >= '0' && c <= '9') return c - '0' + 52;
	if (c == '+' || c == '-') return 62;	// Also accept the URL-safe alphabet
	if (c == '/' || c == '_') return 63;
	return -1;
}

//>>>
static int b64_decode(Tcl_Interp* interp, const char* s, Tcl_Size len, Tcl_Obj** resPtr) //<<<
{
	Tcl_Obj*	res = NULL;
	uint32_t	acc = 0;
	int			bits = 0;
	Tcl_Size	o = 0;

	defer { replace_tclobj(&res, NULL); }

	while (len > 0 && s[len-1] == '=') len--;
	replace_tclobj(&res, Tcl_NewByteArrayObj(NULL, 0));
	uint8_t*	out = Tcl_SetByteArrayLength(res, len * 3 / 4 + 1);

	for (Tcl_Size i=0; i<len; i++) {
		const int	v = b64_value(s[i]);
		if (v < 0) THROW_PRINTF("Invalid base64 character '%c' in blob value", s[i]);
		acc = (acc << 6) | (uint32_t)v;
		bits += 6;
		if (bits >= 8) {
			bits -= 8;
			out[o++] = (uint8_t)(acc >> bits);
		}
	}
	Tcl_SetByteArrayLength(res, o);
	replace_tclobj(resPtr, res);
	return TCL_OK;
}

//>>>
// base64 >>>
// encode <<<
static int enc_generic(Tcl_Interp* interp, CBOR_Buf* b, Tcl_Obj* jval, int depth);
static int enc_shaped(Tcl_Interp* interp, CBOR_Buf* b, Tcl_Obj* jval, Tcl_Obj* shapename, Tcl_Obj* shapes, int depth);

static int jstring(Tcl_Interp* interp, Tcl_Obj* jval, Tcl_Obj** strPtr) //<<<
{
	return JSON_GetObjFromJStringObj(interp, jval, strPtr);
}

//>>>
static int enc_object(Tcl_Interp* interp, CBOR_Buf* b, Tcl_Obj* jval, Tcl_Obj* members, Tcl_Obj* valueshape, Tcl_Obj* shapes, int depth) //<<<
{
	// members: struct member dict (wirekey -> shape), valueshape: map value
	// shape, neither: generic
	Tcl_Obj*	keys = NULL;
	Tcl_Obj*	path = NULL;
	Tcl_Obj*	child = NULL;
	Tcl_Size	keyc;
	Tcl_Obj**	keyv;

	defer {
		replace_tclobj(&keys, NULL);
		replace_tclobj(&path, NULL);
		replace_tclobj(&child, NULL);
	}

	TEST_OK(JSON_Keys(interp, jval, NULL, &keys));
	TEST_OK(Tcl_ListObjGetElements(interp, keys, &keyc, &keyv));
	CBOR_EmitHead(b, CBOR_MT_MAP, keyc);
	for (Tcl_Size i=0; i<keyc; i++) {
		Tcl_Size	klen;
		const char*	k = Tcl_GetStringFromObj(keyv[i], &klen);
		CBOR_EmitText(b, k, klen);

		replace_tclobj(&path, Tcl_NewListObj(1, &keyv[i]));
		TEST_OK(JSON_Extract(interp, jval, path, &child));

		Tcl_Obj*	childshape = valueshape;
		if (members) TEST_OK(Tcl_DictObjGet(interp, members, keyv[i], &childshape));
		if (childshape) {
			TEST_OK(enc_shaped(interp, b, child, childshape, shapes, depth+1));
		} else {
			TEST_OK(enc_generic(interp, b, child, depth+1));
		}
	}
	return TCL_OK;
}

//>>>
static int enc_array(Tcl_Interp* interp, CBOR_Buf* b, Tcl_Obj* jval, Tcl_Obj* elemshape, Tcl_Obj* shapes, int depth) //<<<
{
	Tcl_Size	elemc;
	Tcl_Obj**	elemv;

	TEST_OK(JSON_JArrayObjGetElements(interp, jval, &elemc, &elemv));
	CBOR_EmitHead(b, CBOR_MT_ARRAY, elemc);
	for (Tcl_Size i=0; i<elemc; i++) {
		if (elemshape) {
			TEST_OK(enc_shaped(interp, b, elemv[i], elemshape, shapes, depth+1));
		} else {
			TEST_OK(enc_generic(interp, b, elemv[i], depth+1));
		}
	}
	return TCL_OK;
}

//>>>
static int enc_generic(Tcl_Interp* interp, CBOR_Buf* b, Tcl_Obj* jval, int depth) //<<<
{
	// RFC 8949 section 6.2: the obvious mapping, numbers by their JSON form
	Tcl_Obj*	v = NULL;
	defer { replace_tclobj(&v, NULL); }

	if (depth > MAX_DEPTH) THROW_PRINTF("Request body nesting exceeds %d levels", MAX_DEPTH);

	switch (JSON_GetJSONType(jval)) {
		case JSON_OBJECT:	return enc_object(interp, b, jval, NULL, NULL, NULL, depth);
		case JSON_ARRAY:	return enc_array(interp, b, jval, NULL, NULL, depth);
		case JSON_STRING: {
			Tcl_Size	len;
			TEST_OK(jstring(interp, jval, &v));
			const char*	s = Tcl_GetStringFromObj(v, &len);
			CBOR_EmitText(b, s, len);
			return TCL_OK;
		}
		case JSON_NUMBER:
			TEST_OK(JSON_GetObjFromJNumberObj(interp, jval, &v));
			return CBOR_EmitNumber(interp, b, v);
		case JSON_BOOL: {
			int	bv;
			TEST_OK(JSON_GetObjFromJBooleanObj(interp, jval, &v));
			TEST_OK(Tcl_GetBooleanFromObj(interp, v, &bv));
			CBOR_EmitBool(b, bv);
			return TCL_OK;
		}
		case JSON_NULL:
			CBOR_EmitNull(b);
			return TCL_OK;
		default:
			THROW_PRINTF("Unexpected JSON type %d in request body", (int)JSON_GetJSONType(jval));
	}
}

//>>>
static int enc_float(Tcl_Interp* interp, CBOR_Buf* b, Tcl_Obj* jval) //<<<
{
	Tcl_Obj*	v = NULL;
	double		d;
	defer { replace_tclobj(&v, NULL); }

	switch (JSON_GetJSONType(jval)) {
		case JSON_NUMBER:
			TEST_OK(JSON_GetObjFromJNumberObj(interp, jval, &v));
			TEST_OK(Tcl_GetDoubleFromObj(interp, v, &d));
			break;
		case JSON_STRING: {	// The json protocols' representation of the special values
			TEST_OK(jstring(interp, jval, &v));
			const char*	s = Tcl_GetString(v);
			// Not NAN / INFINITY: jitc 0.8.6 (libslimcc) evaluates both macros to 0
			if      (strcmp(s, "NaN")       == 0) d = nan("");
			else if (strcmp(s, "Infinity")  == 0) d = HUGE_VAL;
			else if (strcmp(s, "-Infinity") == 0) d = -HUGE_VAL;
			else TEST_OK(Tcl_GetDoubleFromObj(interp, v, &d));
			break;
		}
		default:
			return enc_generic(interp, b, jval, 0);
	}
	CBOR_EmitFloat(b, d);
	return TCL_OK;
}

//>>>
static int enc_timestamp(Tcl_Interp* interp, CBOR_Buf* b, Tcl_Obj* jval) //<<<
{
	// Tag 1 (epoch seconds) wrapping a float, even for whole seconds, as the
	// Smithy protocol tests expect
	Tcl_Obj*	v = NULL;
	double		d;
	defer { replace_tclobj(&v, NULL); }

	if (JSON_GetJSONType(jval) != JSON_NUMBER) return enc_generic(interp, b, jval, 0);
	TEST_OK(JSON_GetObjFromJNumberObj(interp, jval, &v));
	TEST_OK(Tcl_GetDoubleFromObj(interp, v, &d));
	CBOR_EmitHead(b, CBOR_MT_TAG, 1);
	CBOR_EmitFloat(b, d);
	return TCL_OK;
}

//>>>
static int enc_shaped(Tcl_Interp* interp, CBOR_Buf* b, Tcl_Obj* jval, Tcl_Obj* shapename, Tcl_Obj* shapes, int depth) //<<<
{
	Tcl_Obj*	desc = NULL;
	Tcl_Size	descc;
	Tcl_Obj**	descv;
	Tcl_Obj*	v = NULL;
	defer { replace_tclobj(&v, NULL); }

	if (depth > MAX_DEPTH) THROW_PRINTF("Request body nesting exceeds %d levels", MAX_DEPTH);

	const enum json_types	type = JSON_GetJSONType(jval);
	if (type == JSON_NULL) {
		CBOR_EmitNull(b);
		return TCL_OK;
	}

	TEST_OK(Tcl_DictObjGet(interp, shapes, shapename, &desc));
	if (!desc) return enc_generic(interp, b, jval, depth);
	TEST_OK(Tcl_ListObjGetElements(interp, desc, &descc, &descv));
	if (descc < 1) return enc_generic(interp, b, jval, depth);

	switch (Tcl_GetString(descv[0])[0]) {
		case 'S':
			if (type != JSON_OBJECT || descc < 2) break;
			return enc_object(interp, b, jval, descv[1], NULL, shapes, depth);
		case 'M':
			if (type != JSON_OBJECT || descc < 2) break;
			return enc_object(interp, b, jval, NULL, descv[1], shapes, depth);
		case 'L':
			if (type != JSON_ARRAY || descc < 2) break;
			return enc_array(interp, b, jval, descv[1], shapes, depth);
		case 'd':
			return enc_float(interp, b, jval);
		case 't':
			return enc_timestamp(interp, b, jval);
		case 'x': {
			if (type != JSON_STRING) break;
			Tcl_Obj*	bytes = NULL;
			Tcl_Size	slen, blen;
			defer { replace_tclobj(&bytes, NULL); }
			TEST_OK(jstring(interp, jval, &v));
			const char*	s = Tcl_GetStringFromObj(v, &slen);
			TEST_OK(b64_decode(interp, s, slen, &bytes));
			const uint8_t*	bp = Tcl_GetBytesFromObj(interp, bytes, &blen);
			if (!bp) return TCL_ERROR;
			CBOR_EmitBytes(b, bp, blen);
			return TCL_OK;
		}
	}
	return enc_generic(interp, b, jval, depth);
}

//>>>
OBJCMD(encode) //<<<
{
	(void)cdata;
	enum {A_cmd, A_DOC, A_SHAPE, A_SHAPES, A_objc};
	CHECK_ARGS("doc shape shapes");

	CBOR_Buf	b;
	CBOR_BufInit(&b);
	defer { CBOR_BufFree(&b); }

	TEST_OK(JSON_ForceJSON(interp, objv[A_DOC]));
	TEST_OK(enc_shaped(interp, &b, objv[A_DOC], objv[A_SHAPE], objv[A_SHAPES], 0));
	Tcl_SetObjResult(interp, CBOR_BufResult(&b));
	return TCL_OK;
}

//>>>
// encode >>>
// decode <<<
static int dec_item(Tcl_Interp* interp, const uint8_t** pPtr, const uint8_t* e, Tcl_Obj** resPtr, int depth);

static int dec_key(Tcl_Interp* interp, const uint8_t** pPtr, const uint8_t* e, Tcl_Obj** keyPtr) //<<<
{
	// Map keys: text strings, and integers in their decimal form
	const uint8_t*	p0 = *pPtr;
	const uint8_t*	p = p0;
	CBOR_Head		h;

	TEST_OK(CBOR_ReadHead(interp, &p, e, &h));
	switch (h.mt) {
		case CBOR_MT_TEXT:
		case CBOR_MT_UINT:
		case CBOR_MT_NINT:
			return CBOR_DecodeValue(interp, pPtr, e, keyPtr, NULL);
		default:
			THROW_PRINTF("Unsupported CBOR map key type %d in response", (int)h.mt);
	}
}

//>>>
static int dec_item(Tcl_Interp* interp, const uint8_t** pPtr, const uint8_t* e, Tcl_Obj** resPtr, int depth) //<<<
{
	const uint8_t*	p0 = *pPtr;
	const uint8_t*	p = p0;
	CBOR_Head		h;
	Tcl_Obj*		v = NULL;
	Tcl_Obj*		acc = NULL;
	Tcl_Obj*		key = NULL;
	Tcl_Obj*		elem = NULL;

	defer {
		replace_tclobj(&v, NULL);
		replace_tclobj(&acc, NULL);
		replace_tclobj(&key, NULL);
		replace_tclobj(&elem, NULL);
	}

	if (depth > MAX_DEPTH) THROW_PRINTF("Response nesting exceeds %d levels", MAX_DEPTH);

	TEST_OK(CBOR_ReadHead(interp, &p, e, &h));

	switch (h.mt) {
		case CBOR_MT_UINT:
		case CBOR_MT_NINT:	// Let the package handle values beyond 64 bits
			TEST_OK(CBOR_DecodeValue(interp, pPtr, e, &v, NULL));
			return JSON_NewJNumberObj(interp, v, resPtr);

		case CBOR_MT_BYTES: {
			Tcl_Size		len;
			TEST_OK(CBOR_DecodeValue(interp, pPtr, e, &v, NULL));	// Joins indefinite-length chunks
			const uint8_t*	bytes = Tcl_GetBytesFromObj(interp, v, &len);
			if (!bytes) return TCL_ERROR;
			replace_tclobj(&acc, b64_encode(bytes, len));
			return JSON_NewJStringObj(interp, acc, resPtr);
		}

		case CBOR_MT_TEXT:
			TEST_OK(CBOR_DecodeValue(interp, pPtr, e, &v, NULL));
			return JSON_NewJStringObj(interp, v, resPtr);

		case CBOR_MT_ARRAY:
			replace_tclobj(&acc, Tcl_NewListObj(0, NULL));
			for (uint64_t i=0; h.indefinite || i < h.val; i++) {
				if (h.indefinite) {
					if (p >= e) THROW_PRINTF("CBOR value truncated");
					if (*p == 0xff) {p++; break;}
				}
				TEST_OK(dec_item(interp, &p, e, &elem, depth+1));
				TEST_OK(Tcl_ListObjAppendElement(interp, acc, elem));
			}
			{
				Tcl_Size	elemc;
				Tcl_Obj**	elemv;
				TEST_OK(Tcl_ListObjGetElements(interp, acc, &elemc, &elemv));
				TEST_OK(JSON_NewJArrayObj(interp, elemc, elemv, resPtr));
			}
			*pPtr = p;
			return TCL_OK;

		case CBOR_MT_MAP:
			replace_tclobj(&acc, Tcl_NewDictObj());
			for (uint64_t i=0; h.indefinite || i < h.val; i++) {
				if (h.indefinite) {
					if (p >= e) THROW_PRINTF("CBOR value truncated");
					if (*p == 0xff) {p++; break;}
				}
				TEST_OK(dec_key(interp, &p, e, &key));
				TEST_OK(dec_item(interp, &p, e, &elem, depth+1));
				TEST_OK(Tcl_DictObjPut(interp, acc, key, elem));
			}
			replace_tclobj(resPtr, JSON_NewJvalObj(JSON_OBJECT, acc));
			*pPtr = p;
			return TCL_OK;

		case CBOR_MT_TAG:
			if (h.val == 2 || h.val == 3) {	// Bignums
				TEST_OK(CBOR_DecodeValue(interp, &p, e, &v, NULL));
				TEST_OK(CBOR_ApplyTag(interp, h.val, v, &acc));
				TEST_OK(JSON_NewJNumberObj(interp, acc, resPtr));
			} else {	// Including tag 1 (epoch timestamps): the tagged value
				TEST_OK(dec_item(interp, &p, e, resPtr, depth+1));
			}
			*pPtr = p;
			return TCL_OK;

		case CBOR_MT_SIMPLE:
			*pPtr = p;
			if (h.isbreak) THROW_PRINTF("Unexpected CBOR break in response");
			switch (h.ai) {
				// (the JSON_New* calls don't necessarily keep the value object:
				// hold a reference so it's released either way)
				case 20:
				case 21:
					replace_tclobj(&v, Tcl_NewBooleanObj(h.ai == 21));
					return JSON_NewJBooleanObj(interp, v, resPtr);
				case 25:
				case 26:
				case 27:
					if (isnan(h.fval)) {
						replace_tclobj(&v, Tcl_NewStringObj("NaN", 3));
						return JSON_NewJStringObj(interp, v, resPtr);
					}
					if (isinf(h.fval)) {
						replace_tclobj(&v, Tcl_NewStringObj(h.fval < 0 ? "-Infinity" : "Infinity", -1));
						return JSON_NewJStringObj(interp, v, resPtr);
					}
					replace_tclobj(&v, Tcl_NewDoubleObj(h.fval));
					return JSON_NewJNumberObj(interp, v, resPtr);
				default:	// null, undefined, unassigned simple values
					return JSON_NewJNullObj(interp, resPtr);
			}
	}
	THROW_PRINTF("Unhandled CBOR major type %d", (int)h.mt);
}

//>>>
OBJCMD(decode) //<<<
{
	(void)cdata;
	enum {A_cmd, A_BYTES, A_objc};
	CHECK_ARGS("bytes");

	Tcl_Size		len;
	const uint8_t*	p = Tcl_GetBytesFromObj(interp, objv[A_BYTES], &len);
	if (!p) return TCL_ERROR;
	const uint8_t*	e = p + len;
	Tcl_Obj*		res = NULL;
	defer { replace_tclobj(&res, NULL); }

	TEST_OK(dec_item(interp, &p, e, &res, 0));
	if (p != e) THROW_PRINTF("Excess bytes after CBOR response");
	Tcl_SetObjResult(interp, res);
	return TCL_OK;
}

//>>>
// decode >>>

// vim: ft=c foldmethod=marker foldmarker=<<<,>>> ts=4 shiftwidth=4
