import Foundation

extension User {
    /// The user as Spectre's JSON export, format 2, with stored passwords
    /// encrypted. What this library does not read of the file it came from
    /// goes back as it was.
    public func exportData() throws -> Data {
        guard isRedacted, !sites.contains(where: \.hasPlainLogin) else { throw SpectreError.passwordsInTheClear }
        var user = JSONObject()
        user["avatar"] = .integer(avatar)
        user["full_name"] = .string(name)
        if let identicon = identicon.nonEmpty {
            user["identicon"] = .string(identicon)
        }
        user["algorithm"] = .integer(algorithm.rawValue)
        if let keyID = keyID.nonEmpty {
            user["key_id"] = .string(keyID)
        }
        user["default_type"] = .integer(defaultType.rawValue)
        if let loginType {
            user["login_type"] = .integer(loginType.rawValue)
            if loginType.isStateful, let loginState = loginState.nonEmpty {
                user["login_name"] = .string(loginState)
            }
        }
        user["last_used"] = .string(Timestamp.format(lastUsed))

        var sites = JSONObject()
        for site in self.sites {
            sites[site.name] = .object(site.exported)
        }
        var export = JSONObject()
        export["format"] = .integer(2)
        export["redacted"] = .bool(true)
        export["date"] = .string(Timestamp.format(Date()))
        var file = JSONObject()
        file["export"] = .object(export.appending(exportExtras))
        file["user"] = .object(user.appending(extras))
        file["sites"] = .object(sites)
        return Data(JSON.object(file.appending(fileExtras)).formatted.utf8)
    }
}

extension Site {
    fileprivate var exported: JSONObject {
        var site = JSONObject()
        site["counter"] = .integer(counter)
        site["algorithm"] = .integer(algorithm.rawValue)
        site["type"] = .integer(type.rawValue)
        if type.isStateful, let state = state.nonEmpty {
            site["password"] = .string(state)
        }
        if let loginType {
            site["login_type"] = .integer(loginType.rawValue)
            if loginType.isStateful, let loginState = loginState.nonEmpty {
                site["login_name"] = .string(loginState)
            }
        }
        if uses > 0 {
            site["uses"] = .integer(uses)
        }
        site["last_used"] = .string(Timestamp.format(lastUsed))
        if !questions.isEmpty {
            var answers = JSONObject()
            for question in questions {
                var answer = JSONObject()
                answer["type"] = .integer(question.type.rawValue)
                if question.type.isStateful, let state = question.state.nonEmpty {
                    answer["answer"] = .string(state)
                }
                answers[question.keyword] = .object(answer.appending(question.extras))
            }
            site["questions"] = .object(answers)
        }
        // Spectre keeps a site's website in _ext_spectre, Master Password in
        // _ext_mpw, which Spectre does not read.
        var extras = self.extras
        if let url = url.nonEmpty {
            var spectre = JSONObject()
            spectre["url"] = .string(url)
            extras["_ext_spectre"] = .object(spectre.appending(extras["_ext_spectre"]?.object ?? JSONObject()))
        } else if let value = extras["_ext_spectre"] {
            var spectre = value.object ?? JSONObject()
            spectre["url"] = nil
            extras["_ext_spectre"] = spectre.isEmpty ? nil : .object(spectre)
        }
        if let spectre = extras.removeValue(forKey: "_ext_spectre") {
            site["_ext_spectre"] = spectre
        }
        return site.appending(extras)
    }
}

extension JSON {
    static func integer(_ value: some BinaryInteger) -> JSON { .number(String(value)) }
}
