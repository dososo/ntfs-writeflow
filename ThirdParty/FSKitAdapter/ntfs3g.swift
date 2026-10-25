//
//  ntfs3g.swift
//  ntfs3g
//
//  Created by kkHAIKE on 2026/6/19.
//

import ExtensionFoundation
import Foundation
import FSKit

@main
struct ntfs3g : UnaryFileSystemExtension {
    let fileSystem = ntfs3gFileSystem()
}
