import AppKit
import SwiftUI

struct CepessaSessionAttachmentPreviewView: View {
  let attachment: LocalMeetingAttachment

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ZStack {
      Color.black
        .ignoresSafeArea()

      VStack(alignment: .leading, spacing: 18) {
        header

        Group {
          if let image = attachmentImage {
            imageSurface(for: image)
          } else {
            missingImageSurface
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .padding(24)
    }
    .frame(minWidth: 760, minHeight: 560)
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(attachment.title)
          .scaledFont(size: 18, weight: .semibold, design: .rounded)
          .foregroundColor(.white)
          .lineLimit(2)

        HStack(spacing: 8) {
          Text(attachment.fileName ?? "Image attachment")
            .scaledFont(size: 12, weight: .medium)
            .foregroundColor(.white.opacity(0.72))
            .lineLimit(1)

          if let note = attachment.note, !note.isEmpty {
            Text(note)
              .scaledFont(size: 12)
              .foregroundColor(.white.opacity(0.58))
              .lineLimit(1)
          }
        }
      }

      Spacer(minLength: 0)

      Button {
        dismiss()
      } label: {
        Label("Close", systemImage: "xmark")
          .scaledFont(size: 12, weight: .semibold)
          .foregroundColor(.white)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(Color.white.opacity(0.12))
          .clipShape(Capsule())
      }
      .buttonStyle(.plain)
      .help("Close image preview")
      .accessibilityLabel("Close image preview")
    }
  }

  @ViewBuilder
  private func imageSurface(for image: NSImage) -> some View {
    GeometryReader { proxy in
      Image(nsImage: image)
        .resizable()
        .scaledToFit()
        .frame(
          maxWidth: proxy.size.width,
          maxHeight: proxy.size.height,
          alignment: .center
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.34), radius: 24, x: 0, y: 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
          RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color.white.opacity(0.04))
        )
    }
  }

  private var missingImageSurface: some View {
    VStack(spacing: 14) {
      Image(systemName: "photo")
        .scaledFont(size: 28, weight: .semibold)
        .foregroundColor(.white.opacity(0.72))

      Text("This attachment is not available as a local image file.")
        .scaledFont(size: 14, weight: .medium)
        .foregroundColor(.white.opacity(0.72))
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(Color.white.opacity(0.05))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .stroke(Color.white.opacity(0.12), lineWidth: 1)
    )
  }

  private var attachmentImage: NSImage? {
    guard attachment.kind == .image || attachment.kind == .capture else { return nil }

    if let urlString = attachment.urlString {
      if urlString.hasPrefix("/") {
        return NSImage(contentsOfFile: urlString)
      }

      if let url = URL(string: urlString), url.isFileURL {
        return NSImage(contentsOf: url)
      }
    }

    return nil
  }
}
