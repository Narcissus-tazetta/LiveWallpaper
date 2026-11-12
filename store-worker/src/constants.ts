export const MAX_UPLOAD_BYTES = 500 * 1024 * 1024; // 500MB, per plan
export const ALLOWED_CONTENT_TYPES = new Set(["application/octet-stream"]);
export const MAX_THUMBNAIL_BYTES = 2 * 1024 * 1024; // 2MB, plenty above the ~15-40KB expected size
export const ALLOWED_THUMBNAIL_CONTENT_TYPES = new Set(["image/jpeg"]);
export const PRESIGNED_URL_TTL_SECONDS = 900;
// Presigned PUT URLs stay usable after /submit, so the submitter could swap the stored bytes
// (keeping the signed size) after a reviewer has looked. Every URL for an entry is issued
// before its /submit, so once this long has passed since created_at none can still write;
// review previews and approval wait until then. The extra minute absorbs clock skew with R2.
export const UPLOAD_WINDOW_MS = (PRESIGNED_URL_TTL_SECONDS + 60) * 1000;
// 署名URLの失効後にも送信途中の時計ずれを吸収しつつ、未submit実体を回収する猶予。
export const ORPHAN_UPLOAD_GRACE_SECONDS = 2 * 60 * 60;
// .lwpkg はZIPなので審査用プレビューはWorker内でメモリ展開してから動画部分だけを
// 返す。ZIP本体(この値まで)と展開後の動画バッファ(ほぼ同サイズ、metadata/previews
// は無視できるほど小さい)が同時にメモリ上に載るため、ピークはこの値のおよそ2倍になる。
// Workers Isolateのメモリ上限(128MB)に対して十分な余裕(JS実行時オーバーヘッド分)を
// 残すため、2倍しても128MBを大きく下回るこの値を上限に据える(超える投稿はプレビュー
// 不可とし、/admin/review/:token/download での生ファイルダウンロードに倒す)。
export const MAX_VIDEO_PREVIEW_BYTES = 48 * 1024 * 1024;
export const MAX_REVIEW_VIDEO_EXPANDED_BYTES = MAX_VIDEO_PREVIEW_BYTES;
// unzipSync は展開先サイズを制限しても、入力ZIP自体は先にメモリへ読むため、
// インラインプレビューで受け入れるアーカイブサイズにも独立した上限を設ける。
export const MAX_PREVIEW_ARCHIVE_BYTES = 64 * 1024 * 1024;
export const REPORT_THRESHOLD = 3;
// 通報通知と審査依頼の両方の送信先(運営本人のメールアドレス)。
export const ADMIN_NOTIFY_EMAIL = "contact@prason.dev";
// Resend only sends from domains verified in its dashboard (prason.dev).
export const STORE_EMAIL_FROM = "LiveWallpaper Store <store@prason.dev>";
export const MAX_DESCRIPTION_LENGTH = 2000;
export const MAX_LICENSE_LENGTH = 200;
export const MAX_REPORT_REASON_LENGTH = 1000;
export const REVIEW_TOKEN_TTL_MS = 48 * 60 * 60 * 1000; // 48時間

export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
