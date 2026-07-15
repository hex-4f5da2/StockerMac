import Foundation

@main
enum ParserChecks {
    static func main() {
        let sinaCN = #"var hq_str_sh600000="浦发银行,9.200,9.190,9.160,9.210,9.070,9.150,9.160,81396248,743787542.000,139100,9.150,203400,9.140,201000,9.130,252200,9.120,609100,9.110,184700,9.160,297300,9.170,288500,9.180,458139,9.190,932000,9.200,2026-07-14,15:34:59,00";"#
        let cn = QuoteParser.parseSina(sinaCN, market: .cn)
        precondition(cn.first?.code == "SH600000")
        precondition(cn.first?.name == "浦发银行")
        precondition(cn.first?.current == 9.16)
        precondition(cn.first?.percentage == -0.33)

        let sinaHK = #"var hq_str_hk00700="TENCENT,腾讯控股,457.600,457.600,459.200,447.400,456.200,-1.400,-0.306,456.20001,456.39999,11581046064,25540540,0.000,0.000,675.134,411.000,2026/07/14,16:09";"#
        let hk = QuoteParser.parseSina(sinaHK, market: .hk)
        precondition(hk.first?.code == "00700")
        precondition(hk.first?.current == 456.2)
        precondition(hk.first?.percentage == -0.31)

        let tencentUS = #"v_usAAPL="200~苹果~AAPL.OQ~317.31~315.32~317.02~43257804~0~0~317.78~40~0~0~0~0~0~0~0~0~317.88~40~0~0~0~0~0~0~0~0~~2026-07-13 16:00:01~1.99~0.63~323.45~315.78~USD";"#
        let us = QuoteParser.parseTencent(tencentUS, market: .us)
        precondition(us.first?.code == "AAPL")
        precondition(us.first?.current == 317.31)
        precondition(us.first?.percentage == 0.63)

        print("Parser checks passed: Sina CN/HK and Tencent US")
    }
}
