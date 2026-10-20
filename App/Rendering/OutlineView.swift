import AppKit
import SwiftUI

struct NativeOutlineNode: Equatable {
    let id:String
    let title:String
    var subtitle:String = ""
    var symbol:String = "folder"
    var children:[NativeOutlineNode] = []
    var expandable=false
}
struct OutlineContextAction {
    let title:String
    let perform:() -> Void
}
/// Shared native outline: AppKit owns keyboard traversal, disclosure and type selection.
struct OutlineView:NSViewRepresentable {
    var accessibilityID="nativeOutline"
    var roots:[NativeOutlineNode]
    var selection:String?
    var expanded:Set<String>
    var scrollAnchor:String?
    var selected:(String?) -> Void
    var expansion:(String,Bool) -> Void
    var scrolled:((String?) -> Void)? = nil
    var contextActions:((String) -> [OutlineContextAction])? = nil
    var displayed:((String) -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context:Context) -> NSScrollView {
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true;scroll.autohidesScrollers=true
        let outline=MenuOutlineView();outline.setAccessibilityIdentifier(accessibilityID);outline.headerView=nil;outline.rowSizeStyle = .default;outline.style = .sourceList;outline.allowsEmptySelection=true;outline.allowsMultipleSelection=false
        outline.backgroundColor = .clear;scroll.drawsBackground=false
        let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("name"));column.width=300;outline.addTableColumn(column);outline.outlineTableColumn=column
        outline.dataSource=context.coordinator;outline.delegate=context.coordinator;outline.menuProvider={ [weak coordinator=context.coordinator] row in coordinator?.menu(row) }
        context.coordinator.outline=outline
        scroll.documentView=outline;scroll.contentView.postsBoundsChangedNotifications=true
        context.coordinator.observe(scroll)
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        let coordinator=context.coordinator;coordinator.parent=self;coordinator.outline?.setAccessibilityIdentifier(accessibilityID);coordinator.update()
    }
    @MainActor final class Coordinator:NSObject,NSOutlineViewDataSource,NSOutlineViewDelegate {
        final class Item:NSObject { var node:NativeOutlineNode;var children:[Item] = [];init(_ node:NativeOutlineNode) { self.node=node } }
        var parent:OutlineView
        weak var outline:NSOutlineView?
        var roots:[Item]=[]
        var items:[String:Item]=[:]
        var applying=false
        var lastRoots:[NativeOutlineNode]=[]
        var initialScrollRestored=false
        var observation:NSObjectProtocol?
        var menuActions:[() -> Void]=[]
        init(_ parent:OutlineView) { self.parent=parent }
        isolated deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
        func observe(_ scroll:NSScrollView) {
            observation=NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:scroll.contentView,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self,!self.applying,let outline=self.outline else { return }
                    let row=outline.row(at:scroll.contentView.bounds.origin)
                    self.parent.scrolled?((outline.item(atRow:max(0,row)) as? Item)?.node.id)
                }
            }
        }
        func update() {
            guard let outline else { return };applying=true;defer { applying=false }
            if lastRoots != parent.roots {
                let previous=items;var next:[String:Item]=[:]
                func build(_ node:NativeOutlineNode) -> Item {
                    let item=previous[node.id] ?? Item(node);item.node=node;next[node.id]=item;item.children=node.children.map(build);return item
                }
                let oldRootIDs=roots.map { $0.node.id }
                let oldChildren=Dictionary(uniqueKeysWithValues:previous.map { ($0.key,$0.value.children.map { $0.node.id }) })
                let oldNodes=Dictionary(uniqueKeysWithValues:previous.map { ($0.key,$0.value.node) })
                roots=parent.roots.map(build);items=next;lastRoots=parent.roots
                if oldRootIDs != roots.map({ $0.node.id }) { outline.reloadData() }
                else {
                    // Reload only changed parents/rows while retaining native item identities.
                    for item in items.values {
                        if oldChildren[item.node.id] != item.children.map({ $0.node.id }) { outline.reloadItem(item,reloadChildren:true) }
                        else if oldNodes[item.node.id]?.title != item.node.title || oldNodes[item.node.id]?.subtitle != item.node.subtitle { outline.reloadItem(item,reloadChildren:false) }
                    }
                }
            }
            // Parents first: NSOutlineView ignores expanding an item whose parent is still collapsed.
            func applyExpansion(_ item:Item) {
                if item.node.expandable || !item.children.isEmpty {
                    if parent.expanded.contains(item.node.id) { outline.expandItem(item) }
                    else { outline.collapseItem(item) }
                }
                item.children.forEach(applyExpansion)
            }
            roots.forEach(applyExpansion)
            if let selection=parent.selection,let item=items[selection],outline.row(forItem:item) >= 0 {
                let row=outline.row(forItem:item)
                if outline.selectedRow != row { outline.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false) }
            } else if outline.selectedRow >= 0 { outline.deselectAll(nil) }
            if !initialScrollRestored,let anchor=parent.scrollAnchor,let item=items[anchor],outline.row(forItem:item)>=0 { outline.scrollRowToVisible(outline.row(forItem:item));initialScrollRestored=true }
        }
        func outlineView(_ outlineView:NSOutlineView,numberOfChildrenOfItem item:Any?) -> Int { (item as? Item)?.children.count ?? roots.count }
        func outlineView(_ outlineView:NSOutlineView,child index:Int,ofItem item:Any?) -> Any { (item as? Item)?.children[index] ?? roots[index] }
        func outlineView(_ outlineView:NSOutlineView,isItemExpandable item:Any) -> Bool { guard let item=item as? Item else { return false };return item.node.expandable || !item.children.isEmpty }
        func outlineView(_ outlineView:NSOutlineView,objectValueFor tableColumn:NSTableColumn?,byItem item:Any?) -> Any? { (item as? Item)?.node.title }
        func outlineView(_ outlineView:NSOutlineView,viewFor tableColumn:NSTableColumn?,item:Any) -> NSView? {
            guard let item=item as? Item else { return nil }
            let cell=NSTableCellView();let label=NSTextField(labelWithString:item.node.title+(item.node.subtitle.isEmpty ? "" : "  · "+item.node.subtitle));label.lineBreakMode = .byTruncatingTail;label.translatesAutoresizingMaskIntoConstraints=false
            let icon=NSImageView(image:NSImage(systemSymbolName:item.node.symbol,accessibilityDescription:nil) ?? NSImage());icon.translatesAutoresizingMaskIntoConstraints=false
            cell.addSubview(icon);cell.addSubview(label);cell.textField=label;cell.imageView=icon
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:3),icon.centerYAnchor.constraint(equalTo:cell.centerYAnchor),icon.widthAnchor.constraint(equalToConstant:16),icon.heightAnchor.constraint(equalToConstant:16),label.leadingAnchor.constraint(equalTo:icon.trailingAnchor,constant:6),label.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-4),label.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
            cell.setAccessibilityIdentifier("outlineRow-"+item.node.id)
            cell.setAccessibilityLabel(item.node.title+" "+item.node.subtitle)
            return cell
        }
        func outlineView(_ outlineView:NSOutlineView,didAdd rowView:NSTableRowView,forRow row:Int) {
            if let item=outlineView.item(atRow:row) as? Item {
                rowView.setAccessibilityIdentifier("outlineRow-"+item.node.id)
                parent.displayed?(item.node.id)
            }
        }
        func outlineViewSelectionDidChange(_ notification:Notification) { guard !applying,let outline else { return };parent.selected((outline.item(atRow:outline.selectedRow) as? Item)?.node.id) }
        // Expansion is reported once, after AppKit expands (shouldExpand would report the same click twice).
        func outlineViewItemDidExpand(_ notification:Notification) { guard !applying,let item=notification.userInfo?["NSObject"] as? Item else { return };parent.expansion(item.node.id,true) }
        func outlineViewItemDidCollapse(_ notification:Notification) { guard !applying,let item=notification.userInfo?["NSObject"] as? Item else { return };parent.expansion(item.node.id,false) }
        func menu(_ row:Int) -> NSMenu? {
            guard let outline,let item=outline.item(atRow:row) as? Item,let actions=parent.contextActions?(item.node.id),!actions.isEmpty else { return nil }
            let menu=NSMenu();menuActions=actions.map(\.perform)
            for (index,action) in actions.enumerated() { let entry=NSMenuItem(title:action.title,action:#selector(runMenu(_:)),keyEquivalent:"");entry.target=self;entry.tag=index;menu.addItem(entry) };return menu
        }
        @objc func runMenu(_ sender:NSMenuItem) { guard menuActions.indices.contains(sender.tag) else { return };menuActions[sender.tag]() }
    }
}
/// Internal so the PR keyboard monitor can leave type-to-select in these trees alone.
@MainActor final class MenuOutlineView:NSOutlineView {
    var menuProvider:((Int) -> NSMenu?)?
    override func menu(for event:NSEvent) -> NSMenu? { menuProvider?(row(at:convert(event.locationInWindow,from:nil))) }
}
