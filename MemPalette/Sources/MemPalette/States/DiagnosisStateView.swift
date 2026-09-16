import SwiftUI

/// State B — query "why is my mac slow": a bulleted diagnosis followed by
/// recommended actions, first one pre-selected with a "↵" hint (1d).
struct DiagnosisStateView: View {
    @State private var selectedAction = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Diagnosis").padding(.top, 8).padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 9) {
                ForEach(MockData.diagnosis) { point in
                    DiagnosisBullet(point: point)
                }
            }
            .padding(.horizontal, Metrics.rowSidePadding)

            SectionHeader(title: "Recommended actions").padding(.top, 18).padding(.bottom, 6)

            VStack(spacing: 0) {
                ForEach(Array(MockData.diagnosisActions.enumerated()), id: \.element.id) { index, action in
                    RecommendationItem(action: action, isSelected: selectedAction == index) { hovering in
                        if hovering { selectedAction = index }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.windowPadding)
        .padding(.bottom, 10)
        .onAppear { selectedAction = 0 }
    }
}
