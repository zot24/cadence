import SwiftUI
import CadenceCore

/// A browsable, shadcn/agentcn-style gallery of agent recipes. Picking one
/// prefills the New Agent Job sheet (project + provider + cadence), so a user
/// installs and schedules a local, tracked agent in a couple of clicks.
struct RecipeGalleryView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Recipe Gallery", systemImage: "square.grid.2x2").font(.headline)
                Spacer()
            }
            .padding()
            Divider()

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.shippableRecipes) { recipe in card(recipe) }
                }
                .padding()
            }

            Divider()
            HStack {
                Text("\(model.shippableRecipes.count) recipes — each scaffolds a local, tracked agent you can run on a schedule.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 700, height: 560)
    }

    private func card(_ recipe: Recipe) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: recipe.symbol).font(.title2).foregroundStyle(.tint)
                Spacer()
                Text(recipe.runtime.rawValue.capitalized)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Text(recipe.title).font(.callout.weight(.semibold))
            Text(recipe.description)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack {
                Text(recipe.suggestedCron)
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button("Use") { use(recipe) }
                    .controlSize(.small).buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .frame(height: 175, alignment: .top)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    private func use(_ recipe: Recipe) {
        model.pendingRecipe = recipe
        model.showingRecipeGallery = false
        // Let the gallery dismiss before presenting the New Agent sheet.
        DispatchQueue.main.async { model.showingNewAgent = true }
    }
}
