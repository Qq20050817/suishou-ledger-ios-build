import SwiftUI
import UIKit
import ReceiptCore

@MainActor @objc(IndependentLedgerController)
final class IndependentLedgerController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let host=UIHostingController(rootView:IndependentLedgerHome(onClose: { [weak self] in self?.dismiss(animated: true) }))
        addChild(host);view.addSubview(host.view);host.view.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([host.view.topAnchor.constraint(equalTo:view.topAnchor),host.view.bottomAnchor.constraint(equalTo:view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo:view.leadingAnchor),host.view.trailingAnchor.constraint(equalTo:view.trailingAnchor)])
        host.didMove(toParent:self)
    }
    override func viewWillAppear(_ animated: Bool) {super.viewWillAppear(animated);navigationController?.setNavigationBarHidden(true,animated:false)}
}

private struct IndependentLedgerHome: View {
    let onClose: () -> Void
    @StateObject private var model = IndependentLedgerModel()
    @Environment(\.scenePhase) private var scene
    @State private var month = OfflineLedger.month(of:Date())
    @State private var entry = false
    @State private var connection = false
    @State private var advanced = false
    @State private var detail: StandaloneEntry?
    private static let types = ["expense":"支出","income":"收入","transfer":"转账","refund":"退款","unknown":"其他"]
    private let tint=Color(red:0.15,green:0.46,blue:0.39)
    var body: some View {
        NavigationStack {
            List {
                Section {
                    let budget=model.ledger.budget(in:month)
                    VStack(alignment:.leading,spacing:10){
                        HStack {
                            Text("本月预算余额").font(.subheadline)
                            Spacer()
                            Menu {
                                ForEach(availableMonths,id:\.self) { m in Button(m) {month=m} }
                            } label:{Label(month,systemImage:"calendar").font(.subheadline)}
                        }
                        Text(budget.limit.map{money($0-budget.used)} ?? "尚未设置").font(.system(.largeTitle,design:.rounded,weight:.bold)).monospacedDigit()
                        Text("计入预算的净支出  "+money(budget.used)).font(.footnote)
                    }.foregroundStyle(.white).padding(.vertical,10)
                }.listRowBackground(tint)
                Section {
                    Button {entry=true} label:{Label("记一笔",systemImage:"plus.circle.fill").font(.headline)}
                    Button {connection=true} label:{
                        HStack{Label("同步",systemImage:"arrow.triangle.2.circlepath");Spacer();Text(syncStatus).font(.footnote).foregroundStyle(.secondary)}
                    }
                }
                Section("账目") {
                    let rows=model.ledger.transactions(in:month)
                    if rows.isEmpty {
                        Text(model.ledger.remote == nil ? "这台设备尚未同步历史账目。联网后连接账本即可查看。"
                             : "这个月没有流水。可以点月份查看以前的记录。").foregroundStyle(.secondary)
                    }
                    ForEach(rows) { item in
                        Button {detail=item} label:{
                            HStack{
                                VStack(alignment:.leading,spacing:4){
                                    Text(item.merchant ?? item.category).foregroundStyle(.primary)
                                    Text(item.category+" · "+item.date.formatted(date:.abbreviated,time:.omitted)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment:.trailing,spacing:4){
                                    Text((item.kind=="expense" ? "−" : (["refund","income"].contains(item.kind) ? "+" : ""))+money(item.cents,item.currency)).monospacedDigit()
                                    Text(model.ledger.pending.contains(where:{$0.id==item.id}) ? "待同步" : Self.types[item.kind] ?? "其他").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("离线账本").tint(tint)
            .toolbar { ToolbarItem(placement:.topBarLeading){Button("完成",action:onClose)}
                ToolbarItem(placement:.topBarTrailing){Button("完整账本",systemImage:"rectangle.stack"){advanced=true}} }
            .refreshable{await model.sync()}
            .sheet(isPresented:$entry){IndependentEntryForm(model:model)}
            .sheet(isPresented:$connection){IndependentConnection(model:model)}
            .sheet(isPresented:$advanced){NavigationStack{FullLedger().navigationTitle("完整账本").navigationBarTitleDisplayMode(.inline).toolbar{ToolbarItem(placement:.confirmationAction){Button("完成"){advanced=false}}}}}
            .sheet(item:$detail){row in
                NavigationStack{List{LabeledContent("金额",value:money(row.cents,row.currency))
                    LabeledContent("类别",value:row.category);LabeledContent("类型",value:Self.types[row.kind] ?? "其他")
                    LabeledContent("时间",value:row.date.formatted());if let v=row.merchant{LabeledContent("商户",value:v)}
                    if let v=row.note{LabeledContent("备注",value:v)}
                    if row.hasReceipt{Button("在完整账本查看凭证"){detail=nil;Task{@MainActor in try? await Task.sleep(for:.milliseconds(350));advanced=true}}}
                }.navigationTitle("账目详情").toolbar{ToolbarItem(placement:.confirmationAction){Button("完成"){detail=nil}}}}
            }
            .task { while !Task.isCancelled {await model.sync();try? await Task.sleep(for:.seconds(45))} }
            .onChange(of:scene){_,phase in if phase == .active {Task{await model.sync()}} }
        }
    }
    private var syncStatus:String {
        if model.syncing{return "正在同步"}
        if !model.ledger.pending.isEmpty {return "\(model.ledger.pending.count) 笔待同步"}
        if !model.signedIn{return "连接独立账本"}
        return model.message.isEmpty ? "已连接" : model.message
    }
    private var availableMonths:[String] {
        var set=Set(model.ledger.entries.map{OfflineLedger.month(of:$0.date)})
        set.formUnion((model.ledger.remote?.budgets ?? []).map(\.month))
        set.formUnion([month,OfflineLedger.month(of:Date())])
        return set.sorted(by:>)
    }
}
private func money(_ cents:Int64,_ currency:String="CNY")->String {
    let value=cents.magnitude
    let amount=String(value/100)+"."+String(format:"%02d",Int(value%100))
    return (cents<0 ? "−" : "")+(currency=="CNY" ? "¥" : currency+" ")+amount
}
private struct FullLedger:UIViewControllerRepresentable{
    func makeUIViewController(context:Context)->UIViewController{
        guard let cls=NSClassFromString("LedgerController") as? UIViewController.Type else{return UIViewController()}
        return cls.init()
    }
    func updateUIViewController(_ uiViewController:UIViewController,context:Context){}
}
private struct IndependentConnection:View{
    @ObservedObject var model:IndependentLedgerModel
    @Environment(\.dismiss) var dismiss
    @State private var password=""
    @State private var busy=false
    @State private var screenshotID: String?
    @State private var reviewCardID: String?
    @State private var showingScreenshot = false
    @State private var screenshotMessage = ""
    var body:some View{NavigationStack {Form{
        Section("独立同步服务"){Text("ledger-sync.xiaokai123.de5.net").font(.subheadline)
            if !model.signedIn {
                SecureField("独立账本密码",text:$password).textContentType(.password)
                Button("连接并同步"){busy=true;Task{_ = await model.signIn(password);password="";busy=false}}.disabled(password.isEmpty||busy)
            }else{Button("立即同步"){Task{await model.sync()}}.disabled(model.syncing)}
        }
        if let id = screenshotID {
            Section("上张截图") {
                Button("继续上张截图记账") {
                    Task {
                        do {
                            reviewCardID = try await ScreenshotInbox.continueReview(id)
                            screenshotMessage = ""
                            showingScreenshot = true
                        } catch { screenshotMessage = error.localizedDescription }
                    }
                }
                if !screenshotMessage.isEmpty { Text(screenshotMessage).font(.footnote) }
                Link("查看待核对小票", destination: IndependentLedgerModel.origin.appendingPathComponent("receipts/screenshots"))
            }
        }
        Section("本机账本"){LabeledContent("待同步",value:"\(model.ledger.pending.count) 笔")
            if let date=model.ledger.lastSync{LabeledContent("上次同步",value:date.formatted())}
            if !model.message.isEmpty{Text(model.message).font(.footnote)}
        }
    }.task { screenshotID = try? ScreenshotInbox.latest() }
     .sheet(isPresented: $showingScreenshot) {
         if let id = reviewCardID { ScreenshotAppReview(id: id) }
     }
     .navigationTitle("同步").toolbar{ToolbarItem(placement:.confirmationAction){Button("完成"){dismiss()}}}}}
}
/// Only the foreground app samples the current paper. Dismissing this sheet ends the task.
private struct ScreenshotAppReview: View {
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: ReceiptSnapshot?
    var body: some View {
        NavigationStack {
            ScrollView {
                if let snapshot { ReceiptSnippetView(snapshot: snapshot, inApp: true).padding() }
            }
            .navigationTitle("截图小票").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .task(id: id) {
            let generation = try? await ReceiptStore.shared.prepareScreenshotFeed(id)
            snapshot = try? await ReceiptStore.shared.snapshot(id)
            if let generation {
                await ReceiptMotionDriver.presentScreenshot(id, generation: generation, inApp: true)
            }
            while !Task.isCancelled {
                snapshot = try? await ReceiptStore.shared.snapshot(id)
                try? await Task.sleep(for: .milliseconds(170))
            }
        }
    }
}

private struct IndependentEntryForm:View{
    @ObservedObject var model:IndependentLedgerModel
    @Environment(\.dismiss) var dismiss
    @State private var amount = ""
    @State private var category = "餐饮"
    @State private var merchant = ""
    @State private var note = ""
    @State private var kind = "expense"
    @State private var original = ""
    @State private var included = true
    @State private var date = Date()
    @State private var error=""
    var body:some View{NavigationStack{Form{
        Picker("类型",selection:$kind){Text("支出").tag("expense");Text("收入").tag("income");Text("退款").tag("refund");Text("转账").tag("transfer")}
            .pickerStyle(.segmented).onChange(of:kind){_,v in category=["expense":"餐饮","income":"收入","refund":"退款","transfer":"转账"][v] ?? "其他"}
        TextField("金额（元）",text:$amount).keyboardType(.decimalPad)
        TextField("分类",text:$category);TextField("商户（可选）",text:$merchant)
        DatePicker("时间",selection:$date,in:Date(timeIntervalSince1970:0)...Date().addingTimeInterval(86400*365))
        if kind=="expense"{Toggle("计入当月预算",isOn:$included)}
        if kind=="refund"{Picker("关联原支出",selection:$original){
            Text("暂不关联").tag("")
            ForEach(model.ledger.entries.filter{$0.kind=="expense"}){r in Text((r.merchant ?? r.category)+" "+money(r.cents,r.currency)+" "+r.date.formatted(date:.abbreviated,time:.omitted)).tag(r.id)}
        }}
        TextField("备注（可选）",text:$note,axis:.vertical)
        if !error.isEmpty{Text(error).foregroundStyle(.red)}
    }.navigationTitle("记一笔").toolbar{
        ToolbarItem(placement:.cancellationAction){Button("取消"){dismiss()}}
        ToolbarItem(placement:.confirmationAction){Button("保存"){save()}}
    }}}
    private func save(){
        let c=category.trimmingCharacters(in:.whitespacesAndNewlines)
        guard let cents=OfflineLedger.amount(amount),!c.isEmpty,c.utf16.count<=40,
              merchant.utf16.count<=120,note.utf16.count<=500 else {error="请填写有效金额和分类，或缩短商户与备注。";return}
        let budget=kind=="expense" && included
        let r=StandaloneEntry(occurredAt:Int64(date.timeIntervalSince1970*1000),kind:kind,cents:cents,category:c,merchant:merchant.isEmpty ? nil:merchant,
            note:note.isEmpty ? nil:note,included:budget,budgetMonth:budget ? OfflineLedger.month(of:date):nil,originalID:kind=="refund" && !original.isEmpty ? original:nil)
        if model.record(r){dismiss()}else{error=model.message}
    }
}
