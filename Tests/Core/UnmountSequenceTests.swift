import Foundation
import Darwin

@main enum UnmountSequenceTests {
    static func main() throws {
        var operations: [String] = []
        do {
            try DiskService.synchronizeAndUnmount(descriptor: 42, synchronize: { descriptor in
                precondition(descriptor == 42)
                operations.append("同步")
                errno = EIO
                return -1
            }, dismount: { _, _ in
                fatalError("同步失败后不得请求卸载")
            })
            fatalError("同步失败不得报告成功")
        } catch let error as DiskOperationError {
            precondition(error.message.contains("同步未完成（\(EIO)）"))
            precondition(error.message.contains("已保留挂载"))
        }
        precondition(operations == ["同步"])

        operations = []
        try DiskService.synchronizeAndUnmount(descriptor: 42, synchronize: { descriptor in
            precondition(descriptor == 42)
            operations.append("同步")
            return 0
        }, dismount: { descriptor, flags in
            precondition(descriptor == 42 && flags == 0)
            operations.append("正常卸载")
            return 0
        })
        precondition(operations == ["同步", "正常卸载"])

        do {
            try DiskService.synchronizeAndUnmount(descriptor: 42, synchronize: { _ in 0 }, dismount: { _, flags in
                precondition(flags == 0)
                errno = EBUSY
                return -1
            })
            fatalError("占用失败不得报告成功")
        } catch let error as DiskOperationError {
            precondition(error.message.contains("卷未卸载（\(EBUSY)）"))
        }
        print("卸载序列 3 项通过：同步失败不卸载、先同步后正常卸载、占用失败不报成功；未接触设备。")
    }
}
