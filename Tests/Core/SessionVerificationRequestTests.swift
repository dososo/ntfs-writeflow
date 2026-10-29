import Foundation

@main enum SessionVerificationRequestTests {
    static func main() {
        let now = Date(timeIntervalSince1970:1000)
        let raw: [String:Any] = ["版本":1,"编号":"ABCDEF01-2345-4678-9ABC-DEF012345678","创建时间":900.0,"到期时间":1100.0]
        func check(_ value:Bool,_ reason:String) { if !value { print("失败：\(reason)"); exit(1) } }
        check(SessionVerificationRequest.parse(raw,now:now) != nil,"有效限时配置被拒绝")
        check(SessionVerificationRequest.parse(nil,now:now) == nil,"缺配置应默认关闭")
        for (key,value) in [("版本",true as Any),("版本",2),("编号","bad"),("编号","abcdef01-2345-4678-9abc-def012345678"),
                            ("创建时间",true),("创建时间",-1.0),("创建时间",1001.0),("创建时间",Double.nan),
                            ("到期时间",1000.0),("到期时间",true),("到期时间",Double.infinity),("到期时间",22501.0)] {
            var invalid=raw; invalid[key]=value
            check(SessionVerificationRequest.parse(invalid,now:now)==nil,"无效字段\(key)未被拒绝")
        }
        var maximum=raw;maximum["到期时间"]=22500.0
        check(SessionVerificationRequest.parse(maximum,now:now) != nil,"精确六小时配置应接受")
        var extra=raw;extra["输出路径"]="/tmp/untrusted"
        check(SessionVerificationRequest.parse(extra,now:now)==nil,"外加路径字段应拒绝")
        check(SessionVerificationRequest.parse(raw,now:Date(timeIntervalSince1970:1100))==nil,"过期配置不应记录")
        print("限时会话验收配置17项通过；缺失/无效/过期默认不记录，不改变操作许可。")
    }
}
