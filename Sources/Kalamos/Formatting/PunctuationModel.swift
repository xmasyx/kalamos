import CoreML
import Foundation
import Tokenizers

/// Il modello dedicato di punteggiatura (L1): XLM-RoBERTa large affinato sul
/// restauro dei segni, eseguito in CoreML. Sceglie un'etichetta per parola —
/// niente, `.` `,` `?` `-` `:` — e PER COSTRUZIONE non può cambiare le parole:
/// è il motivo per cui la sua copertura è 100% dove l'LLM sta al 96,8%.
///
/// Misurato sul banco (metro d'autore, 40 frasi): punto 81,2 · virgola 73,6 ·
/// domanda 74,5 di F1 a 19 ms di mediana, contro i 3,3 s dell'LLM da 4 GB.
actor PunctuationModel {
    static let shared = PunctuationModel()

    /// Finestra fissa del modello convertito, riempita con <pad>=1 e mask 0.
    private static let seq = 256
    private static let padID = 1
    /// Parole per finestra: identico al banco (max misurato sull'archivio
    /// intero: 162 sottotoken per 150 parole, il [1,256] basta).
    private static let finestra = 150

    private var modello: MLModel?
    private var tokenizer: Tokenizer?
    private var id2label: [Int: String] = [:]

    // ------------------------------------------------------------- lo scarico

    /// Da dove viene il modello, alla lettera: repo di terzi su Hugging Face,
    /// MIT, base dichiarata oliverguhr/fullstop-punctuation-multilang-large,
    /// PINNATO alla revisione verificata dal banco. Un aggiornamento del repo
    /// non cambia ciò che l'app scarica: i numeri misurati valgono per QUESTI
    /// byte, non per il nome del repo.
    private static let repo = "soloish90/fullstop-punctuation-coreml-fp16"
    private static let rev = "338c2a1a"
    /// I file del pacchetto compilato, con la taglia esatta: la verifica di
    /// taglia è il cancello fra «scaricato» e «scaricato a metà» (il download
    /// del banco è morto due volte a metà: exit 56 a 874 MB su 1.118).
    private static let files: [(rel: String, bytes: Int)] = [
        ("coremldata.bin", 441),
        ("metadata.json", 2669),
        ("model.mil", 265_564),
        ("weights/weight.bin", 1_118_241_216),
        ("analytics/coremldata.bin", 243),
    ]

    /// Il tokenizer scende INSIEME al modello, e non è una comodità: un
    /// tokenizer spedito nel bundle e un modello scaricato dopo sono due cose
    /// che l'aggiornamento può separare in silenzio, e un tokenizer diverso
    /// non dà un errore — dà una punteggiatura diversa. Scaricandoli insieme,
    /// ognuno pinnato alla sua revisione, la coppia non può divergere.
    ///
    /// Viene dal modello ORIGINALE (`oliverguhr`, MIT), non dalla conversione
    /// CoreML di terzi, che il tokenizer non lo contiene.
    private static let tokRepo = "oliverguhr/fullstop-punctuation-multilang-large"
    private static let tokRev = "345e80adc07e761d3a35feafd20f2f44a151f453"
    /// `config.json` porta `id2label`, `tokenizer.json` è il vocabolario vero.
    /// Taglie di upstream, byte per byte.
    private static let tokFiles: [(rel: String, bytes: Int)] = [
        ("config.json", 892),
        ("tokenizer.json", 17_098_080),
    ]
    /// Il terzo file è a parte perché è l'UNICO che tocchiamo: `oliverguhr` lo
    /// scrisse nel 2021 senza `tokenizer_class`, e senza quel campo
    /// swift-transformers deriva «Xlm-RobertaTokenizer» dal `model_type` e
    /// muore. Si scarica pristino (406 byte di upstream, verificati), poi si
    /// riscrive col campo aggiunto — perciò la sua integrità non si misura in
    /// byte ma sul contenuto: vedi `tokenizerConfigOK`.
    private static let tokConfigName = "tokenizer_config.json"
    private static let tokConfigBytes = 406
    private static let tokClass = "XLMRobertaTokenizer"

    /// `<Application Support>/Kalamos/punctuation/<rev>/punctuation.mlmodelc`
    static var modelDir: URL {
        puntoBase.appendingPathComponent("punctuation.mlmodelc", isDirectory: true)
    }

    /// `<Application Support>/Kalamos/punctuation/<rev>/tokenizer`
    static var tokenizerDir: URL {
        puntoBase.appendingPathComponent("tokenizer", isDirectory: true)
    }

    /// La cartella è keyed sulla revisione del MODELLO: il tokenizer vive
    /// dentro la stessa, così la coppia si sposta o si butta insieme.
    private static var puntoBase: URL {
        ModelStorage.base
            .appendingPathComponent("punctuation", isDirectory: true)
            .appendingPathComponent(rev, isDirectory: true)
    }

    private static func taglia(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
    }

    /// Il `tokenizer_config.json` è a posto se parsifica E dichiara la classe.
    /// Un controllo sul contenuto, non sui byte, perché quel file lo scriviamo
    /// noi: misurarne la taglia vorrebbe dire inseguire la nostra stessa patch.
    private static var tokenizerConfigOK: Bool {
        let url = tokenizerDir.appendingPathComponent(tokConfigName)
        guard let data = FileManager.default.contents(atPath: url.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return json["tokenizer_class"] as? String == tokClass
    }

    /// Scaricato E integro: modello e tokenizer, ogni file alla taglia esatta.
    static var isDownloaded: Bool { isModelDownloaded && isTokenizerDownloaded }

    static var isModelDownloaded: Bool {
        files.allSatisfy { taglia(modelDir.appendingPathComponent($0.rel)) == $0.bytes }
    }

    static var isTokenizerDownloaded: Bool {
        tokFiles.allSatisfy { taglia(tokenizerDir.appendingPathComponent($0.rel)) == $0.bytes }
            && tokenizerConfigOK
    }

    /// Scarica i file del modello e quelli del tokenizer, uno per uno, e
    /// verifica la taglia. Un file già integro non si riscarica (riprendere
    /// costa zero).
    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        // Il `tokenizer_config.json` entra nel conto con la taglia di upstream:
        // è quella che viaggia sulla rete.
        let totale = files.reduce(0) { $0 + $1.bytes }
            + tokFiles.reduce(0) { $0 + $1.bytes } + tokConfigBytes
        var fatti = 0

        func scarica(_ url: URL, verso dest: URL, attesi: Int, nome: String) async throws {
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let (tmp, risposta) = try await URLSession.shared.download(from: url)
            guard let http = risposta as? HTTPURLResponse, http.statusCode == 200 else {
                throw NSError(domain: "PunctuationModel", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "HTTP \((risposta as? HTTPURLResponse)?.statusCode ?? -1) su \(nome)"])
            }
            let size = taglia(tmp) ?? -1
            guard size == attesi else {
                try? FileManager.default.removeItem(at: tmp)
                throw NSError(domain: "PunctuationModel", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "\(nome): \(size) byte invece di \(attesi) — scaricamento incompleto"])
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
        }

        for f in files {
            let dest = modelDir.appendingPathComponent(f.rel)
            if taglia(dest) != f.bytes {
                let url = URL(string:
                    "https://huggingface.co/\(repo)/resolve/\(rev)/punctuation.mlmodelc/\(f.rel)")!
                try await scarica(url, verso: dest, attesi: f.bytes, nome: f.rel)
            }
            fatti += f.bytes
            progress(Double(fatti) / Double(totale))
        }

        for f in tokFiles {
            let dest = tokenizerDir.appendingPathComponent(f.rel)
            if taglia(dest) != f.bytes {
                let url = URL(string: "https://huggingface.co/\(tokRepo)/resolve/\(tokRev)/\(f.rel)")!
                try await scarica(url, verso: dest, attesi: f.bytes, nome: f.rel)
            }
            fatti += f.bytes
            progress(Double(fatti) / Double(totale))
        }

        if !tokenizerConfigOK {
            let dest = tokenizerDir.appendingPathComponent(tokConfigName)
            let url = URL(string: "https://huggingface.co/\(tokRepo)/resolve/\(tokRev)/\(tokConfigName)")!
            try await scarica(url, verso: dest, attesi: tokConfigBytes, nome: tokConfigName)
            // La patch, sui byte appena verificati: aggiunge il campo mancante
            // e non tocca nient'altro.
            guard let data = FileManager.default.contents(atPath: dest.path),
                  var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw NSError(domain: "PunctuationModel", code: 8, userInfo: [
                    NSLocalizedDescriptionKey: "\(tokConfigName) scaricato ma illeggibile"])
            }
            json["tokenizer_class"] = tokClass
            let patched = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            try patched.write(to: dest, options: .atomic)
            guard tokenizerConfigOK else {
                throw NSError(domain: "PunctuationModel", code: 9, userInfo: [
                    NSLocalizedDescriptionKey: "\(tokConfigName) riscritto ma senza tokenizer_class"])
            }
        }
        fatti += tokConfigBytes
        progress(Double(fatti) / Double(totale))
    }

    // ------------------------------------------------------------ caricamento

    /// Carica modello e tokenizer, una volta. Percorsi espliciti per il banco
    /// (`--bench-l1`); nil = i percorsi dell'app.
    func prepare(modelURL: URL? = nil, tokenizerDir: URL? = nil) async throws {
        if modello != nil { return }
        let modelPath = modelURL ?? Self.modelDir
        let tokDir = tokenizerDir ?? Self.tokenizerDir
        guard FileManager.default.fileExists(atPath: tokDir.appendingPathComponent("tokenizer.json").path) else {
            throw NSError(domain: "PunctuationModel", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "tokenizer assente in \(tokDir.path) — serve --punct-download"])
        }

        let cfg = MLModelConfiguration()
        // INCHIODATA, non un default dimenticato: `.all` su questo modello
        // produce spazzatura (173 righe rotte su 174, misurato sul banco il
        // 17/08 — virgole ovunque). `.cpuAndGPU` è fedele ED è anche la più
        // veloce (19,3 ms di mediana contro 27,8 di `.all`).
        cfg.computeUnits = .cpuAndGPU
        modello = try MLModel(contentsOf: modelPath, configuration: cfg)
        tokenizer = try await AutoTokenizer.from(modelFolder: tokDir)

        // id2label dal config accanto al tokenizer: mai scritto a mano qui.
        let cfgURL = tokDir.appendingPathComponent("config.json")
        guard let cfgData = FileManager.default.contents(atPath: cfgURL.path),
              let cfgJson = try? JSONSerialization.jsonObject(with: cfgData) as? [String: Any],
              let raw = cfgJson["id2label"] as? [String: String]
        else {
            throw NSError(domain: "PunctuationModel", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "id2label non trovato in \(cfgURL.path)"])
        }
        id2label = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })

        // Giro di riscaldamento, scartato: la prima inferenza paga i buffer.
        _ = try? etichetteFinestra(["giro", "di", "riscaldamento", "che", "non", "conta"])
    }

    var isLoaded: Bool { modello != nil }

    /// Libera modello e tokenizer (il footprint del fp16 è ~1,1 GB).
    func unload() {
        modello = nil
        tokenizer = nil
        id2label = [:]
    }

    // -------------------------------------------------------------- etichette

    /// Un'etichetta per parola per l'intero testo spogliato, a finestre di 150
    /// parole come sul banco.
    func etichette(perParole parole: [String]) throws -> [String] {
        var out: [String] = []
        var i = 0
        while i < parole.count {
            let fine = min(i + Self.finestra, parole.count)
            out.append(contentsOf: try etichetteFinestra(Array(parole[i..<fine])))
            i = fine
        }
        return out
    }

    /// Specchia `etichetta()` di L1C: l'etichetta di una parola è quella del
    /// suo ULTIMO sottotoken; un sottotoken che comincia con "▁" apre una
    /// parola nuova.
    private func etichetteFinestra(_ pezzo: [String]) throws -> [String] {
        guard let modello, let tokenizer else {
            throw NSError(domain: "PunctuationModel", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "modello non caricato"])
        }
        let testo = pezzo.joined(separator: " ")
        var ids = tokenizer.encode(text: testo)
        let tokens = ["<s>"] + tokenizer.tokenize(text: testo) + ["</s>"]
        if ids.count > Self.seq {
            Log.write("punteggiatura: \(ids.count) token > \(Self.seq), finestra troncata")
            ids = Array(ids.prefix(Self.seq))
        }
        guard let inIds = try? MLMultiArray(shape: [1, NSNumber(value: Self.seq)], dataType: .int32),
              let inMask = try? MLMultiArray(shape: [1, NSNumber(value: Self.seq)], dataType: .int32)
        else {
            throw NSError(domain: "PunctuationModel", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "MLMultiArray non allocabile"])
        }
        for i in 0..<Self.seq {
            inIds[i] = NSNumber(value: i < ids.count ? ids[i] : Self.padID)
            inMask[i] = NSNumber(value: i < ids.count ? 1 : 0)
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": inIds, "attention_mask": inMask,
        ])
        let res = try modello.prediction(from: provider)
        guard let preds = res.featureValue(for: "label_preds")?.multiArrayValue else {
            throw NSError(domain: "PunctuationModel", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "label_preds assente dalla risposta del modello"])
        }

        var indicePerParola: [Int] = []
        for t in 0..<min(tokens.count, ids.count) {
            let tk = tokens[t]
            if tk == "<s>" || tk == "</s>" || tk == "<pad>" { continue }
            if tk.hasPrefix("\u{2581}") || indicePerParola.isEmpty {
                indicePerParola.append(t)
            } else {
                indicePerParola[indicePerParola.count - 1] = t
            }
        }
        return (0..<pezzo.count).map { k in
            guard k < indicePerParola.count else { return "0" }
            return id2label[preds[indicePerParola[k]].intValue] ?? "0"
        }
    }
}
