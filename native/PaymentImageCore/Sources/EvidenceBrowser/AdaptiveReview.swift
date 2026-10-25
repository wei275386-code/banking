import SwiftUI

struct ReviewStack<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
#if os(iOS)
        VStack(alignment: .leading, spacing: 12) { content }
#else
        HStack { content }
#endif
    }
}
struct ReviewForm<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
#if os(iOS)
        VStack(alignment: .leading, spacing: 16) { content }.padding(16).background(.background).clipShape(RoundedRectangle(cornerRadius: 16))
#else
        Form { content }
#endif
    }
}
