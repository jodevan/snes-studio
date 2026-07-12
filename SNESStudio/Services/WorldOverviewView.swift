import SwiftUI

/// World overview editor showing all zones and screens
struct WorldOverviewView: View {
    @Bindable var state: AppState
    
    @State private var selectedZoneID: UUID?
    @State private var selectedScreenID: UUID?
    @State private var zoom: CGFloat = 1.0
    
    private var selectedZone: WorldZone? {
        guard let id = selectedZoneID else { return nil }
        return state.assetStore.worldZones.first { $0.id == id }
    }
    
    var body: some View {
        HSplitView {
            // Left: Zone list
            VStack(spacing: 0) {
                Text("Zones")
                    .font(.headline)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(SNESTheme.bgPanel)
                
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(state.assetStore.worldZones) { zone in
                            zoneRow(zone)
                        }
                    }
                    .padding(8)
                }
            }
            .frame(minWidth: 150, idealWidth: 200, maxWidth: 250)
            
            // Right: Zone grid
            if let zone = selectedZone {
                VStack(spacing: 0) {
                    // Toolbar
                    HStack {
                        Text(zone.name)
                            .font(.headline)
                        
                        Spacer()
                        
                        // Zoom controls
                        Button {
                            zoom = max(0.5, zoom - 0.25)
                        } label: {
                            Image(systemName: "minus.magnifyingglass")
                        }
                        
                        Text("\(Int(zoom * 100))%")
                            .frame(width: 50)
                        
                        Button {
                            zoom = min(2.0, zoom + 0.25)
                        } label: {
                            Image(systemName: "plus.magnifyingglass")
                        }
                    }
                    .padding(8)
                    .background(SNESTheme.bgPanel)
                    
                    // Grid
                    ScrollView([.horizontal, .vertical]) {
                        WorldGridCanvas(
                            zone: zone,
                            screens: state.assetStore.worldScreens,
                            selectedScreenID: selectedScreenID,
                            zoom: zoom,
                            onSelectScreen: { screenID in
                                selectedScreenID = screenID
                            },
                            onDoubleClickScreen: { screenID in
                                // Open screen editor
                                state.selectSubTab("screen_\(screenID.uuidString)")
                            }
                        )
                        .padding()
                    }
                }
            } else {
                placeholder("Select a zone")
            }
        }
        .background(SNESTheme.bgEditor)
        .onAppear {
            if selectedZoneID == nil, let firstZone = state.assetStore.worldZones.first {
                selectedZoneID = firstZone.id
            }
        }
    }
    
    // MARK: - Zone Row
    
    private func zoneRow(_ zone: WorldZone) -> some View {
        Button {
            selectedZoneID = zone.id
            selectedScreenID = nil
        } label: {
            HStack {
                Circle()
                    .fill(Color(hex: zone.colorHex))
                    .frame(width: 12, height: 12)
                
                Text(zone.name)
                    .foregroundStyle(SNESTheme.textPrimary)
                
                Spacer()
                
                Text("\(zone.gridWidth)×\(zone.gridHeight)")
                    .font(.caption)
                    .foregroundStyle(SNESTheme.textSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selectedZoneID == zone.id ? SNESTheme.bgPanel : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Placeholder
    
    private func placeholder(_ label: String) -> some View {
        VStack {
            Image(systemName: "map")
                .font(.system(size: 48))
                .foregroundStyle(SNESTheme.textDisabled)
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(SNESTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    WorldOverviewView(state: AppState())
        .frame(width: 800, height: 600)
}
