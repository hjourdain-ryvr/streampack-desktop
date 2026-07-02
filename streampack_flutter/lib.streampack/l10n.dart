import 'package:flutter/material.dart';

// ── Supported languages ───────────────────────────────────────────────────────

enum AppLanguage { en, de, sv, fr }

extension AppLanguageLabel on AppLanguage {
  String get label => switch (this) {
    AppLanguage.en => 'English',
    AppLanguage.de => 'Deutsch',
    AppLanguage.sv => 'Svenska',
    AppLanguage.fr => 'Français',
  };
  String get code => name; // 'en', 'de', 'sv', 'fr'
}

// ── Global language notifier (survives widget rebuilds) ───────────────────────

final languageNotifier = ValueNotifier<AppLanguage>(AppLanguage.en);

// ── Localization strings ──────────────────────────────────────────────────────

class AppLocalizations {
  final AppLanguage lang;
  const AppLocalizations(this.lang);

  // ── App / shell ─────────────────────────────────────────────────────────────
  String get appTitle       => 'StreamPack';
  String get tabEncoder     => const {'de':'ENCODER','sv':'KODARE','fr':'ENCODEUR'}[lang.code] ?? 'ENCODER';
  String get tabValidator   => const {'de':'VALIDATOR','sv':'VALIDATOR','fr':'VALIDATEUR'}[lang.code] ?? 'VALIDATOR';
  String get menuSettings   => const {'de':'Einstellungen','sv':'Inställningar','fr':'Paramètres'}[lang.code] ?? 'Settings';
  String get menuAbout      => const {'de':'Über StreamPack','sv':'Om StreamPack','fr':'À propos'}[lang.code] ?? 'About';

  // ── Settings dialog ─────────────────────────────────────────────────────────
  String get settingsTitle    => const {'de':'Einstellungen','sv':'Inställningar','fr':'Paramètres'}[lang.code] ?? 'Settings';
  String get settingsLanguage => const {'de':'Sprache','sv':'Språk','fr':'Langue'}[lang.code] ?? 'Language';
  String get settingsClose    => const {'de':'Schließen','sv':'Stäng','fr':'Fermer'}[lang.code] ?? 'Close';

  // ── About dialog ────────────────────────────────────────────────────────────
  String get aboutDescription =>
    const {
      'de': 'HLS & DASH Adaptive-Streaming-Encoder\nfür Linux und Windows.',
      'sv': 'HLS & DASH adaptiv strömnings-encoder\nför Linux och Windows.',
      'fr': 'Encodeur de streaming adaptatif HLS & DASH\npour Linux et Windows.',
    }[lang.code] ?? 'HLS & DASH adaptive streaming encoder\nfor Linux and Windows.';
  String get aboutClose => settingsClose;

  // ── Encoder tab ─────────────────────────────────────────────────────────────
  String get encSource            => const {'de':'Quelle','sv':'Källa','fr':'Source'}[lang.code] ?? 'Source';
  String get encInputFile         => const {'de':'Eingabedatei','sv':'Indatafil','fr':'Fichier source'}[lang.code] ?? 'Input file';
  String get encInputHint         => '/srv/videos/movie.mp4';
  String get encOutputName        => const {'de':'Ausgabename','sv':'Utdatanamn','fr':'Nom de sortie'}[lang.code] ?? 'Output name';
  String get encOutputNameHint    => const {'de':'Standard: Quelldateiname','sv':'Standard: kallfilnamn','fr':'Defaut : nom du fichier source'}[lang.code] ?? 'Default: source file name';
  String get encSourceSize        => const {'de':'Quelle','sv':'Källa','fr':'Source'}[lang.code] ?? 'Source';
  String get encFormat            => const {'de':'Format','sv':'Format','fr':'Format'}[lang.code] ?? 'Format';
  String get encFormatBoth        => const {'de':'Beide','sv':'Båda','fr':'Les deux'}[lang.code] ?? 'Both';
  String get encQuality           => const {'de':'Qualität','sv':'Kvalitet','fr':'Qualité'}[lang.code] ?? 'Quality';
  String get encQualityBalanced   => const {'de':'Ausgewogen','sv':'Balanserad','fr':'Équilibré'}[lang.code] ?? 'Balanced';
  String get encQualityHigh       => const {'de':'Hoch','sv':'Hög','fr':'Haute'}[lang.code] ?? 'High';
  String get encVideoOutput       => const {'de':'Videoausgabe','sv':'Videoutgång','fr':'Sortie vidéo'}[lang.code] ?? 'Video Output';
  String get encDetected          => const {'de':'Erkannt','sv':'Upptäckt','fr':'Détecté'}[lang.code] ?? 'Detected';
  String get encBasic             => const {'de':'Einfach','sv':'Enkel','fr':'Simple'}[lang.code] ?? 'Basic';
  String get encAdvanced          => const {'de':'Erweitert','sv':'Avancerat','fr':'Avancé'}[lang.code] ?? 'Advanced';
  String get encKeep              => const {'de':'Behalten','sv':'Behåll','fr':'Garder'}[lang.code] ?? 'Keep';
  String get encAdvancedNeedsFile => const {'de':'Wählen Sie eine einzelne Datei, um Spuren zu konfigurieren.','sv':'Välj en enda fil för att konfigurera spår.','fr':'Sélectionnez un seul fichier pour configurer les pistes.'}[lang.code] ?? 'Select a single file to configure tracks.';
  String get encAudioTab          => const {'de':'Audio','sv':'Ljud','fr':'Audio'}[lang.code] ?? 'Audio';
  String get encVideoTab          => const {'de':'Video','sv':'Video','fr':'Vidéo'}[lang.code] ?? 'Video';
  String get encSubtitlesTab      => const {'de':'Untertitel','sv':'Undertexter','fr':'Sous-titres'}[lang.code] ?? 'Subtitles';
  String get encPassthrough       => const {'de':'Durchreichen','sv':'Vidarekoppla','fr':'Conserver'}[lang.code] ?? 'Passthrough';
  String get encRemove            => const {'de':'Entfernen','sv':'Ta bort','fr':'Supprimer'}[lang.code] ?? 'Remove';
  String get encDefault           => const {'de':'STANDARD','sv':'STANDARD','fr':'DÉFAUT'}[lang.code] ?? 'DEFAULT';
  String get encStereo            => const {'de':'Stereo','sv':'Stereo','fr':'Stéréo'}[lang.code] ?? 'Stereo';
  String get encNoAudio           => const {'de':'Keine Audiospuren','sv':'Inga ljudspår','fr':'Aucune piste audio'}[lang.code] ?? 'No audio tracks';
  String get encNoSubtitles       => const {'de':'Keine Untertitel','sv':'Inga undertexter','fr':'Aucun sous-titre'}[lang.code] ?? 'No subtitle tracks';
  String get encSubtitlesReadonly => const {'de':'Untertitel werden derzeit nicht in die Ausgabe übernommen.','sv':'Undertexter tas inte med i utdata ännu.','fr':'Les sous-titres ne sont pas encore inclus dans la sortie.'}[lang.code] ?? 'Subtitles are not carried into the output yet.';
  String get encVideoAdvNote      => const {'de':'Codec/Bereich werden oben gewählt.','sv':'Codec/omfång väljs ovan.','fr':'Codec/plage se choisissent ci-dessus.'}[lang.code] ?? 'Codec/range are chosen above.';
  String get encBitrate           => const {'de':'Bitrate','sv':'Bithastighet','fr':'Débit'}[lang.code] ?? 'Bitrate';
  String get encCrf               => 'CRF';
  String get encTargetBitrate     => const {'de':'Ziel','sv':'Mål','fr':'Cible'}[lang.code] ?? 'Target';
  String get encLadderPreview     => const {'de':'Stufen','sv':'Stege','fr':'Échelle'}[lang.code] ?? 'Ladder';
  String get encDefaultWord       => const {'de':'Standard','sv':'standard','fr':'défaut'}[lang.code] ?? 'default';
  String get encCrfNote           => const {'de':'Gleiche Qualität auf allen Auflösungen.','sv':'Samma kvalitet på alla upplösningar.','fr':'Même qualité sur toutes les résolutions.'}[lang.code] ?? 'Same quality on every resolution.';
  String get encVideoUntouchedNote => const {'de':'Basis-Voreinstellung wird verwendet — oben ändern zum Überschreiben.','sv':'Använder grundinställning — ändra ovan för att åsidosätta.','fr':'Qualité de base utilisée — modifiez ci-dessus pour remplacer.'}[lang.code] ?? 'Using Basic preset quality — change above to override.';
  String get encQualityBest       => const {'de':'Beste','sv':'Bästa','fr':'Meilleure'}[lang.code] ?? 'Best';
  String get encEffortNote        => const {'de':'Höher = bessere Qualität, langsamer (NVENC p4/p5/p6).','sv':'Högre = bättre kvalitet, långsammare (NVENC p4/p5/p6).','fr':'Plus élevé = meilleure qualité, plus lent (NVENC p4/p5/p6).'}[lang.code] ?? 'Higher = better quality, slower (NVENC p4/p5/p6).';
  String get encOutputDir         => const {'de':'Ausgabeverzeichnis','sv':'Utdatakatalog','fr':'Dossier de sortie'}[lang.code] ?? 'Output directory';
  String get encHlsOutputDir      => const {'de':'HLS-Ausgabeverzeichnis','sv':'HLS-utdatakatalog','fr':'Dossier de sortie HLS'}[lang.code] ?? 'HLS output directory';
  String get encDashOutputDir     => const {'de':'DASH-Ausgabeverzeichnis','sv':'DASH-utdatakatalog','fr':'Dossier de sortie DASH'}[lang.code] ?? 'DASH output directory';
  String get encRenditions        => const {'de':'Auflösungen','sv':'Upplösningar','fr':'Rendus'}[lang.code] ?? 'Renditions';
  String get encSegmentDuration   => const {'de':'Segmentdauer','sv':'Segmentlängd','fr':'Durée de segment'}[lang.code] ?? 'Segment Duration';
  String get encStartEncoding     => const {'de':'CODIERUNG STARTEN','sv':'STARTA KODNING','fr':'DÉMARRER L\'ENCODAGE'}[lang.code] ?? 'START ENCODING';
  String get encJobQueue          => const {'de':'Job-Warteschlange','sv':'Jobbkö','fr':'File d\'attente'}[lang.code] ?? 'Job Queue';
  String get encNoJobs            => const {'de':'Noch keine Jobs — konfigurieren und codieren','sv':'Inga jobb ännu — konfigurera och koda','fr':'Aucun job — configurez et encodez'}[lang.code] ?? 'No jobs yet — configure and encode';

  // ── Encoder toasts ──────────────────────────────────────────────────────────
  String get toastEnterInput      => const {'de':'Bitte Eingabedatei angeben','sv':'Ange en indatafil','fr':'Entrez un fichier source'}[lang.code] ?? 'Enter an input file path';
  String get toastEnterHlsDir     => const {'de':'Bitte HLS-Ausgabeverzeichnis angeben','sv':'Ange en HLS-utdatakatalog','fr':'Entrez un dossier de sortie HLS'}[lang.code] ?? 'Enter an HLS output directory';
  String get toastEnterDashDir    => const {'de':'Bitte DASH-Ausgabeverzeichnis angeben','sv':'Ange en DASH-utdatakatalog','fr':'Entrez un dossier de sortie DASH'}[lang.code] ?? 'Enter a DASH output directory';
  String get toastSelectRes       => const {'de':'Mindestens eine Auflösung auswählen','sv':'Välj minst en upplösning','fr':'Sélectionnez au moins une résolution'}[lang.code] ?? 'Select at least one resolution';
  String get toastFfmpegMissing   => const {'de':'ffmpeg nicht gefunden — bitte installieren','sv':'ffmpeg hittades inte — installera det','fr':'ffmpeg introuvable — installez-le d\'abord'}[lang.code] ?? 'ffmpeg not found — install it first';

  // ── Encoder status ──────────────────────────────────────────────────────────
  String get statusFfmpegReady    => const {'de':'ffmpeg bereit','sv':'ffmpeg redo','fr':'ffmpeg prêt'}[lang.code] ?? 'ffmpeg ready';
  String get statusFfmpegMissing  => const {'de':'ffmpeg nicht gefunden','sv':'ffmpeg saknas','fr':'ffmpeg introuvable'}[lang.code] ?? 'ffmpeg not found';
  String get statusGpuTooltip     => const {'de':'NVIDIA GPU erkannt — Codierung mit h264_nvenc','sv':'NVIDIA GPU hittad — kodar med h264_nvenc','fr':'GPU NVIDIA détecté — encodage avec h264_nvenc'}[lang.code] ?? 'NVIDIA GPU detected — encoding with h264_nvenc';
  String get statusCpuTooltip     => const {'de':'Keine NVIDIA GPU — Codierung mit libx264','sv':'Ingen NVIDIA GPU — kodar med libx264','fr':'Pas de GPU NVIDIA — encodage avec libx264'}[lang.code] ?? 'No NVIDIA GPU — encoding with libx264';

  // ── Rendition grid ──────────────────────────────────────────────────────────
  String upscaleTooltip(int h)    =>
    const {
      'de': 'Würde hochskalieren — Quellhöhe ist',
      'sv': 'Skulle skala upp — källhöjden är',
      'fr': 'Surascalonnage — hauteur source :',
    }[lang.code] != null
      ? '${const {'de':'Würde hochskalieren — Quellhöhe ist','sv':'Skulle skala upp — källhöjden är','fr':'Surascalonnage — hauteur source :'}[lang.code]} ${h}p'
      : 'Would upscale — source height is ${h}p';
  String get upscaleLabel         => const {'de':'— Hochskalierung','sv':'— uppskalning','fr':'— surescalonnage'}[lang.code] ?? '— upscale';

  // ── Job card ────────────────────────────────────────────────────────────────
  String get jobCancel            => const {'de':'✕ abbrechen','sv':'✕ avbryt','fr':'✕ annuler'}[lang.code] ?? '✕ cancel';
  String get jobCancelAll         => const {'de':'Alle abbrechen','sv':'Avbryt alla','fr':'Tout annuler'}[lang.code] ?? 'Cancel all';
  String get jobRemoveTooltip     => const {'de':'Entfernen','sv':'Ta bort','fr':'Supprimer'}[lang.code] ?? 'Remove';
  String get jobValidating        => const {'de':'validierung…','sv':'validerar…','fr':'validation…'}[lang.code] ?? 'validating…';
  String get jobValidationReport  => const {'de':'Validierungsbericht','sv':'Valideringsrapport','fr':'Rapport de validation'}[lang.code] ?? 'Validation report';
  String skippedRenditions(String r) =>
    const {
      'de': 'Übersprungen (würde hochskalieren): ',
      'sv': 'Hoppade över (skulle skala upp): ',
      'fr': 'Ignorés (surescalonnage) : ',
    }[lang.code] != null
      ? '${const {'de':'Übersprungen (würde hochskalieren): ','sv':'Hoppade över (skulle skala upp): ','fr':'Ignorés (surescalonnage) : '}[lang.code]}$r'
      : 'Skipped (would upscale): $r';
  String get jobStatusQueued      => const {'de':'wartend','sv':'väntar','fr':'en attente'}[lang.code] ?? 'queued';
  String get jobStatusRunning     => const {'de':'läuft','sv':'kör','fr':'en cours'}[lang.code] ?? 'running';
  String get jobStatusValidating  => const {'de':'validierung','sv':'validerar','fr':'validation'}[lang.code] ?? 'validating';
  String get jobStatusDone        => const {'de':'fertig','sv':'klar','fr':'terminé'}[lang.code] ?? 'done';
  String get jobStatusError       => const {'de':'fehler','sv':'fel','fr':'erreur'}[lang.code] ?? 'error';
  String get jobStatusCancelled   => const {'de':'abgebrochen','sv':'avbruten','fr':'annulé'}[lang.code] ?? 'cancelled';

  // ── Validator tab ────────────────────────────────────────────────────────────
  String get valTarget            => const {'de':'Ziel','sv':'Mål','fr':'Cible'}[lang.code] ?? 'Target';
  String get valTargetHint        => '/srv/hls/streams/movie/movie.m3u8';
  String get valValidate          => const {'de':'PRÜFEN','sv':'VALIDERA','fr':'VALIDER'}[lang.code] ?? 'VALIDATE';
  String get valHistory           => const {'de':'Verlauf','sv':'Historik','fr':'Historique'}[lang.code] ?? 'History';
  String get valEmptyPrompt       => const {'de':'Pfad oder URL eingeben und Prüfen klicken','sv':'Ange sökväg eller URL och klicka Validera','fr':'Entrez un chemin ou une URL et cliquez Valider'}[lang.code] ?? 'Enter a path or URL and click Validate';
  String get valEnterTarget       => const {'de':'Bitte Pfad oder URL eingeben','sv':'Ange en sökväg eller URL','fr':'Entrez un chemin ou une URL'}[lang.code] ?? 'Enter a file path or URL';
  String valError(String e)       =>
    const {
      'de': 'Validierungsfehler: ',
      'sv': 'Valideringsfel: ',
      'fr': 'Erreur de validation : ',
    }[lang.code] != null
      ? '${const {'de':'Validierungsfehler: ','sv':'Valideringsfel: ','fr':'Erreur de validation : '}[lang.code]}$e'
      : 'Validation error: $e';

  // ── Validation report ────────────────────────────────────────────────────────
  String get reportPass           => const {'de':'BESTANDEN','sv':'GODKÄND','fr':'RÉUSSI'}[lang.code] ?? 'PASS';
  String get reportWarnings       => const {'de':'WARNUNGEN','sv':'VARNINGAR','fr':'AVERTISSEMENTS'}[lang.code] ?? 'WARNINGS';
  String get reportFailed         => const {'de':'FEHLGESCHLAGEN','sv':'MISSLYCKAD','fr':'ÉCHEC'}[lang.code] ?? 'FAILED';

  // ── File picker dialog titles ────────────────────────────────────────────────
  String get pickInputTitle       => const {'de':'Eingabevideo auswählen','sv':'Välj indatavideo','fr':'Sélectionner la vidéo source'}[lang.code] ?? 'Select input video file';
  String get pickHlsDirTitle      => const {'de':'HLS-Ausgabeverzeichnis auswählen','sv':'Välj HLS-utdatakatalog','fr':'Sélectionner le dossier HLS'}[lang.code] ?? 'Select HLS output directory';
  String get pickDashDirTitle     => const {'de':'DASH-Ausgabeverzeichnis auswählen','sv':'Välj DASH-utdatakatalog','fr':'Sélectionner le dossier DASH'}[lang.code] ?? 'Select DASH output directory';
  String get pickManifestTitle    => const {'de':'HLS- oder DASH-Manifest auswählen','sv':'Välj HLS- eller DASH-manifest','fr':'Sélectionner un manifest HLS ou DASH'}[lang.code] ?? 'Select HLS or DASH manifest';
}

// ── BuildContext extension for easy access ────────────────────────────────────

extension LocalizationContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations(languageNotifier.value);
}
