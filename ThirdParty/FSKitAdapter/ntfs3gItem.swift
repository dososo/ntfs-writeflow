//
//  ntfs3gItem.swift
//  An FSItem backed by an NTFS inode (MFT record number).
//

import FSKit
import Foundation

@available(macOS 15.4, *)
final class ntfs3gItem: FSItem {
    /// NTFS MFT record number (NFSK_ROOT_INO == 2 for the root directory).
    let ino: UInt64
    var parentIno: UInt64
    var name: FSFileName

    init(ino: UInt64, parentIno: UInt64, name: FSFileName) {
        self.ino = ino
        self.parentIno = parentIno
        self.name = name
        super.init()
    }
}
