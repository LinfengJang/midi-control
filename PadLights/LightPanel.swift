import Cocoa
struct PanelState: Codable { let model:String; let preset:Int; let entries:[[UInt8]]; let createdAt:Date }
final class PadTile:NSButton {
    let stripe=CALayer()
    func update(_ color:[UInt8],selected:Bool,known:Bool=true) {
        wantsLayer=true;isBordered=false;alignment = .center
        font = .monospacedSystemFont(ofSize:13,weight:.semibold);contentTintColor = .white
        cell?.wraps=true
        layer?.cornerRadius=12;layer?.borderWidth=selected ? 3:1
        layer?.borderColor=(selected ? NSColor.systemMint:NSColor.darkGray).cgColor
        layer?.backgroundColor=NSColor(calibratedWhite:selected ? 0.22:0.13,alpha:1).cgColor
        if stripe.superlayer == nil { layer?.addSublayer(stripe) }
        stripe.frame=CGRect(x:14,y:bounds.height-15,width:max(0,bounds.width-28),height:4);stripe.cornerRadius=2
        stripe.backgroundColor=(known ? NSColor(srgbRed:CGFloat(color[0])/255,green:CGFloat(color[1])/255,blue:CGFloat(color[2])/255,alpha:1):NSColor.darkGray).cgColor
        let value=known ? (color.allSatisfy{$0==0} ? "已关灯":color.map{String(format:"%02X",$0)}.joined()):"未读取"
        title="\(tag)\n\(value)\n\(selected ? "✓ 已选":"未选")"
        setAccessibilityLabel("打击垫 \(tag) · \(selected ? "已选":"未选") · \(value)")
        needsDisplay=true
    }
}
final class ConsoleConnection {
    var process: Process?, input: FileHandle?, output: FileHandle?
    func stop() { try? input?.close(); input=nil; output=nil; if let p=process { p.waitUntilExit() }; process=nil }
    func request(_ arguments:[String],tool:URL) throws -> PanelState {
        if process == nil || process?.isRunning != true {
            let p=Process(), incoming=Pipe(),outgoing=Pipe()
            p.executableURL=tool;p.arguments=["serve"];p.standardInput=incoming;p.standardOutput=outgoing;p.standardError=FileHandle.nullDevice
            try p.run(); process=p;input=incoming.fileHandleForWriting;output=outgoing.fileHandleForReading
        }
        do {
            var data=try JSONEncoder().encode(arguments); data.append(10);try input!.write(contentsOf:data)
            var line=Data()
            while true {
                guard let byte=try output!.read(upToCount:1),!byte.isEmpty else { throw NSError(domain:"灯光连接已断开，请重新读取",code:1) }
                if byte.first==10 { break };line.append(byte)
                guard line.count < 100000 else { throw NSError(domain:"设备回复异常",code:1) }
            }
            struct Reply:Decodable {let state:PanelState?;let error:String?}
            let reply=try JSONDecoder().decode(Reply.self,from:line)
            guard let state=reply.state else { throw NSError(domain:reply.error ?? "操作未完成",code:1) }
            return state
        } catch { stop();throw error }
    }
}
final class LightPanel:NSObject,NSApplicationDelegate,NSWindowDelegate {
    let connection=ConsoleConnection()
    var window:NSWindow!
    let color=NSColorWell(),status=NSTextField(wrappingLabelWithString:"正在读取十六个打击垫…")
    let countLabel=NSTextField(labelWithString:""),presetLabel=NSTextField(labelWithString:"")
    let progress=NSProgressIndicator()
    var tiles:[PadTile]=[],controls:[NSControl]=[],selection:Set<Int>=[5]
    var state:PanelState?,busy=false
    let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("SMK25II Pad Lights",isDirectory:true)
    var references=UserDefaults.standard.dictionary(forKey:"originalReferences") as? [String:String] ?? [:]
    func row(_ views:[NSView])->NSStackView { let r=NSStackView(views:views);r.spacing=10;r.alignment = .centerY;return r }
    func button(_ title:String,_ action:Selector,_ tag:Int)->NSButton {
        let b=NSButton(title:title,target:self,action:action);b.tag=tag;controls.append(b);return b
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:550),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.delegate=self;window.title="SMK25II · 十六格灯光控制台";window.appearance=NSAppearance(named:.darkAqua)
        let stack=NSStackView();stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=18;stack.translatesAutoresizingMaskIntoConstraints=false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:28),stack.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-28),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:25)])
        let heading=NSTextField(labelWithString:"打击垫灯光控制台");heading.font = .systemFont(ofSize:24,weight:.semibold)
        stack.addArrangedSubview(row([heading,presetLabel]))
        stack.addArrangedSubview(NSTextField(labelWithString:"点击任意方块可多选；排列与键盘一致，上排 1–8，下排 9–16。"))
        for bank in 0..<2 {
            var views:[NSView]=[]
            for index in 1...8 {
                let tile=PadTile(title:"",target:self,action:#selector(toggle(_:)));tile.tag=bank*8+index;tile.isBordered=false
                tile.widthAnchor.constraint(equalToConstant:96).isActive=true;tile.heightAnchor.constraint(equalToConstant:90).isActive=true
                tiles.append(tile);controls.append(tile);views.append(tile)
            }
            stack.addArrangedSubview(row(views))
        }
        stack.addArrangedSubview(row([button("全选",#selector(selectGroup(_:)),0),button("清空选择",#selector(selectGroup(_:)),1),button("选上排",#selector(selectGroup(_:)),2),button("选下排",#selector(selectGroup(_:)),3),button("反选",#selector(selectGroup(_:)),4),countLabel]))
        color.color=NSColor(srgbRed:0,green:170/255,blue:127/255,alpha:1);color.widthAnchor.constraint(equalToConstant:65).isActive=true;controls.append(color)
        stack.addArrangedSubview(row([NSTextField(labelWithString:"颜色"),color,button("选中改色",#selector(act(_:)),0),button("选中开灯",#selector(act(_:)),1),button("选中关灯",#selector(act(_:)),2),button("恢复选中原色",#selector(act(_:)),3)]))
        let allOff=button("全部关灯",#selector(act(_:)),4),allOn=button("全部开灯",#selector(act(_:)),5)
        stack.addArrangedSubview(row([allOff,allOn,button("重新读取",#selector(refreshButton(_:)),0)]))
        progress.style = .spinning;progress.controlSize = .small;progress.isDisplayedWhenStopped=false
        status.maximumNumberOfLines=3;status.widthAnchor.constraint(equalToConstant:800).isActive=true
        stack.addArrangedSubview(row([progress,status]))
        let hint=NSTextField(labelWithString:"开灯恢复各自关灯前的颜色 · 临时控制，不保存预设 · 关闭窗口即退出")
        hint.textColor = .secondaryLabelColor;hint.font = .systemFont(ofSize:11);stack.addArrangedSubview(hint)
        let menu=NSMenu(),appItem=NSMenuItem(),appMenu=NSMenu()
        menu.addItem(appItem);appItem.submenu=appMenu
        let show=NSMenuItem(title:"显示灯光控制台",action:#selector(showWindow),keyEquivalent:"0");show.target=self;appMenu.addItem(show)
        appMenu.addItem(.separator());appMenu.addItem(withTitle:"退出灯光控制台",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");NSApp.mainMenu=menu
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        update();refresh()
    }
    @objc func showWindow(){window.deminiaturize(nil);window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool{showWindow();return true}
    func update() {
        countLabel.stringValue="已选 \(selection.count) / 16"
        presetLabel.stringValue=state.map{"当前预设 \($0.preset)"} ?? "未连接"
        for tile in tiles { tile.update(state.map{Array($0.entries[tile.tag-1][5...7])} ?? [0,0,0],selected:selection.contains(tile.tag),known:state != nil) }
        for control in controls { control.isEnabled = !busy }
    }
    @objc func toggle(_ sender:NSButton) { if selection.contains(sender.tag){selection.remove(sender.tag)}else{selection.insert(sender.tag)};update() }
    @objc func selectGroup(_ sender:NSButton) {
        switch sender.tag {case 0:selection=Set(1...16);case 1:selection=[];case 2:selection=Set(1...8);case 3:selection=Set(9...16);default:selection=Set(1...16).subtracting(selection)};update()
    }
    @objc func refreshButton(_ sender:NSButton){refresh()}
    func prepare() throws {
        try FileManager.default.createDirectory(at:support.appendingPathComponent("Backups"),withIntermediateDirectories:true)
    }
    func execute(_ arguments:[String],message:String) {
        guard !busy,let tool=Bundle.main.url(forResource:"padlights",withExtension:nil) else{return}
        do{try prepare()}catch{status.stringValue="无法创建颜色备份：\(error.localizedDescription)";return}
        busy=true;update();progress.startAnimation(nil);status.stringValue=message
        DispatchQueue.global().async {
            var result:PanelState?,failure=""
            do { result=try self.connection.request(arguments,tool:tool) }
            catch {failure=error.localizedDescription}
            DispatchQueue.main.async {
                self.busy=false;self.progress.stopAnimation(nil)
                if let result,result.model=="SMK25II",result.entries.count==16,result.entries.allSatisfy({$0.count==74}) {
                    self.state=result
                    let key="\(result.preset)"
                    if self.references[key]==nil || !FileManager.default.fileExists(atPath:self.references[key]!) {
                        let reference=self.support.appendingPathComponent("original-preset-\(result.preset).json")
                        do {try JSONEncoder().encode(result).write(to:reference,options:.atomic);self.references[key]=reference.path;UserDefaults.standard.set(self.references,forKey:"originalReferences")}
                        catch{self.status.stringValue="已读取，但无法保存原色参考。";self.update();return}
                    }
                    self.status.stringValue="已完成，十六个打击垫的状态已读回核对。"
                } else {self.status.stringValue="操作未完成：\(failure.trimmingCharacters(in:.whitespacesAndNewlines))"}
                self.update()
            }
        }
    }
    func applicationWillTerminate(_ notification:Notification){connection.stop()}
    func refresh(){execute(["state"],message:"正在读取灯光（首次连接需约两秒）…")}
    @objc func act(_ sender:NSButton) {
        guard let state else{refresh();return}
        let selected=sender.tag>=4 ? Array(1...16):selection.sorted()
        guard !selected.isEmpty else{status.stringValue="请先点击方块选择要控制的打击垫。";return}
        let operation=sender.tag==0 ? "color":sender.tag==1 || sender.tag==5 ? "on":sender.tag==3 ? "restore":"off"
        let c=color.color.usingColorSpace(.sRGB) ?? NSColor.systemMint
        let value=String(format:"%02X%02X%02X",Int((c.redComponent*255).rounded()),Int((c.greenComponent*255).rounded()),Int((c.blueComponent*255).rounded()))
        let backup=support.appendingPathComponent("Backups/\(UUID().uuidString).json").path
        var arguments=["batch","--pads",selected.map(String.init).joined(separator:","),"--operation",operation,"--hex",value,"--backup",backup,"--memory",support.appendingPathComponent("last-lit-colors.json").path]
        if operation=="restore" {
            guard let reference=references["\(state.preset)"] else{status.stringValue="尚无这个预设的原色记录。";return}
            arguments += ["--reference",reference]
        }
        execute(arguments,message:"正在操作 \(selected.count) 个打击垫，完成后会核对未选中部分没有变化…")
    }
    func windowShouldClose(_ sender:NSWindow)->Bool {if busy{status.stringValue="正在执行操作，请完成后再关闭。"};return !busy}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{true}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply{busy ? .terminateCancel:.terminateNow}
}
let app=NSApplication.shared
let delegate=LightPanel();app.delegate=delegate;app.setActivationPolicy(.regular);app.run()
