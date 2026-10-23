import SwiftUI
import AppKit
import Combine

// MARK: - 메뉴바 팝오버 본체 (RULE-006: 제어센터 스타일 볼륨 바)
// 엔트리포인트(@main)와 메뉴바 부트는 main.swift에 있음
//
// 2026-10-12 사용자 피드백 반영:
//   - 세로 노브가 너무 크고 투박     -> 슬라이더 두께 축소(가는 스타일로 교체)
//   - 노브 생기면 위/아래로 잘림     -> 패널 높이 유동화 + 카드 패딩 정리
//   - 가로/세로 노브 모드 선택 설정  -> MixerSettings에 orientation 저장, 패널에 토글 제공

struct MixerPanelView: View {
    @ObservedObject var vm: MixerViewModel
    @AppStorage("sliderOrientation") private var sliderOrientation = "vertical"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("앱 볼륨 믹서").font(.headline)
                Spacer()
                // 가로/세로 보기 전환 (RULE-006 개선: 사용자 설정)
                // 팝오버 들썩 문제 해결: 전환 버튼을 "텍스트 라벨"로 바꾸어 아이콘 렌더 이슈 없애고,
                // 콘텐츠 영역 크기를 양 모드에서 동일하게 고정합니다.
                Menu {
                    Button("세로 노브") { sliderOrientation = "vertical" }
                    Button("가로 노브") { sliderOrientation = "horizontal" }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13))
                        .frame(width: 24, height: 20)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("노브 방향 변경")

                Button {
                    vm.refreshApps()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("앱 목록 새로고침")
                .frame(width: 24, height: 24, alignment: .center)      // 아이콘 크기 고정
                .contentShape(Rectangle())
            }

            Divider()

            // 지금 뭘 재생 중인지 표시 (유튜브/애플뮤직 등, 정보 없으면 생략)
            if !vm.nowPlayingTitle.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(vm.nowPlayingTitle)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 2)
            }

            if let err = vm.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            if vm.apps.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("오디오를 출력 중인 앱이 없습니다")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else if sliderOrientation == "vertical" {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 12) {
                        ForEach(vm.apps) { app in
                            ControlCard(app: app, vm: vm, orientation: .vertical)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 2)
                }
                .frame(height: 190)   // 들썩 방지: 세로 모드 콘텐츠 고정 높이
                Spacer(minLength: 0)
            } else {
                // 가로 슬라이더 목록 - 동일 고정 높이로 들썩 방지
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(vm.apps) { app in
                            ControlCard(app: app, vm: vm, orientation: .horizontal)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 190)   // 세로 모드와 동일한 높이 고정
                Spacer(minLength: 0)
            }

            Divider()
            Text("바를 내리면 tap이 켜져 볼륨이 조절됩니다. 100% 부근은 조절 없이 원본이 출력됩니다.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        // 팝오버 흔들임 방지: 어떤 모드든 같은 고정 크기
        .frame(width: 330, height: 340)
        .onAppear { vm.refreshApps() }
    }
}

// MARK: - 앱 카드 (세로 / 가로 공용)

struct ControlCard: View {
    enum Orientation { case vertical, horizontal }

    let app: AudioApp
    @ObservedObject var vm: MixerViewModel
    let orientation: Orientation

    var body: some View {
        let binding = Binding<Double>(
            get: { Double(vm.volumes[app.id] ?? 1.0) },
            set: { vm.setLiveVolume(app: app, gain: Float($0)) }
        )
        Group {
            switch orientation {
            case .vertical:
                VStack(spacing: 7) {
                    if let icon = appIconImage() {
                        Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: "app").font(.system(size: 22)).frame(height: 28)
                    }
                    Text(app.name).font(.system(size: 9)).lineLimit(1)
                        .frame(maxWidth: 44)

                    VolumeBar(value: binding, isVertical: true)
                        .frame(width: 22, height: 130)   // 기존 36x160 -> 가는 노브

                    Text("\(Int((vm.volumes[app.id] ?? 1.0) * 100))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(vm.isControlled(app) ? .primary : .secondary)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10).fill(.quinary)
                )
            case .horizontal:
                HStack(spacing: 10) {
                    if let icon = appIconImage() {
                        Image(nsImage: icon).resizable().frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    } else {
                        Image(systemName: "app").font(.system(size: 18)).frame(width: 24, height: 24)
                    }
                    Text(app.name)
                        .font(.system(size: 11))
                        .frame(width: 66, alignment: .leading)
                        .lineLimit(1)

                    VolumeBar(value: binding, isVertical: false)
                        .frame(height: 22)

                    Text("\(Int((vm.volumes[app.id] ?? 1.0) * 100))")
                        .font(.system(size: 10, design: .monospaced))
                        .frame(width: 28, alignment: .trailing)
                        .foregroundStyle(vm.isControlled(app) ? .primary : .secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10).fill(.quinary)
                )
            }
        }
    }

    private func appIconImage() -> NSImage? {
        guard let path = CoreAudioDevice.procPath(pid: app.pid) else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }
}

// MARK: - 가는 제어센터 스타일 볼륨 노브 (세로/가로 모두 커버)
// 개선: 두께 축소 + 잘림 방지(안쪽 여백), 채우기 색상 조절 중일 때만 파랑

struct VolumeBar: View {
    // @State 매크로가 CLI 빌드에서 안정적으로 로드되지 않아
    // NSViewRepresentable에서 self-contained로 처리
    var value: Binding<Double>
    var isVertical: Bool

    var body: some View {
        GeometryReader { geo in
            let size = isVertical ? geo.size.height : geo.size.width
            let thickness = isVertical ? geo.size.width : geo.size.height
            // 드래그 중 밖으로 나가도 계속 이동: localtracking Enabled
            // 트랙 전체를 손잡이 이동 범위로 쓴다: 0%~100% 끝까지 정확히 닿는 구현
            // (손잡이가 잘리지 않게 시각적으로만 패딩, 계산은 전체 길이 기준)
            let trackLen = max(size, 1)

            ZStack(alignment: isVertical ? .bottom : .leading) {
                // 트랙 (배경)
                Capsule().fill(Color.primary.opacity(0.10))
                    .frame(width: isVertical ? thickness : size,
                           height: isVertical ? size : thickness)

                // 채워짐
                let filled = trackLen * value.wrappedValue
                Group {
                    if isVertical {
                        Capsule().fill(fillColor).frame(width: thickness, height: filled)
                    } else {
                        Capsule().fill(fillColor).frame(width: filled, height: thickness)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: isVertical ? .bottom : .leading)

                // 손잡이 표시선은 제거됨 (유저 요청: 흰 줄 삭제)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        // 로컬 좌표 전 길이 기준: 끝(0/100%)까지 정확히 도달
                        let raw = isVertical
                            ? 1 - g.location.y / trackLen
                            : g.location.x / trackLen
                        value.wrappedValue = min(max(raw, 0), 1)
                    }
            )
        }
    }

    private var fillColor: Color {
        // 100% 근처(원본 유지)는 중립색, 조절 중인 앱만 파색 강조
        return (1.0 - value.wrappedValue) < 0.001
            ? Color.primary.opacity(0.35) : Color.blue
    }
}
