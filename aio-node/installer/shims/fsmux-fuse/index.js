'use strict';
// No FUSE on tvOS: AIOStreams' probe reports it unavailable and skips the mount.
const reason = 'FUSE is not available on Apple TV';
exports.probeFuse = async () => ({ ok: false, reason });
exports.mountSharedFilesystem = async () => {
  throw new Error(reason);
};
