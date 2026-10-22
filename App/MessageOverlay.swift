import UIKit

/// A full-screen native panel: app icon, title, message, one button (sign in, retry).
final class MessageOverlay: UIView {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let button = UIButton(type: .system)
    private let activity = UIActivityIndicatorView(style: .medium)
    private var action: (() -> Void)?

    func configure(title: String, message: String, button title2: String, buttonID: String, action: @escaping () -> Void) {
        self.action = action
        backgroundColor = .systemBackground

        iconView.image = UIImage(named: "ShellIcon")
        iconView.contentMode = .scaleAspectFit
        iconView.layer.cornerRadius = 22
        iconView.clipsToBounds = true
        iconView.isHidden = iconView.image == nil

        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .title1)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        messageLabel.text = message
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        var config = UIButton.Configuration.filled()
        config.title = title2
        config.cornerStyle = .large
        config.buttonSize = .large
        button.configuration = config
        button.accessibilityIdentifier = buttonID
        button.addAction(UIAction { [weak self] _ in self?.action?() }, for: .touchUpInside)

        activity.hidesWhenStopped = true

        let stack = UIStackView(arrangedSubviews: [iconView, titleLabel, messageLabel, button, activity])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 18
        stack.setCustomSpacing(28, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 96),
            iconView.heightAnchor.constraint(equalToConstant: 96),
            stack.centerYAnchor.constraint(equalTo: safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -32),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
    }

    func setMessage(_ text: String) {
        messageLabel.text = text
    }

    func setBusy(_ busy: Bool) {
        button.isEnabled = !busy
        if busy { activity.startAnimating() } else { activity.stopAnimating() }
    }

    func pin(in parent: UIView) {
        translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: parent.topAnchor),
            bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        ])
    }
}
