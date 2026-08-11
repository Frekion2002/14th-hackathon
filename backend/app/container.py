from __future__ import annotations

from app.config import Settings
from app.database import Database
from app.services.acoustics import UnconfiguredAcousticAnalyzer
from app.services.deepgram import create_stt_gateway
from app.services.gemini import create_extraction_gateway
from app.services.livekit import create_livekit_gateway
from app.services.notifications import create_voip_push_gateway
from app.services.pipeline import ProcessingPipeline
from app.services.reports import ReportService
from app.services.signals import SignalService
from app.services.storage import create_storage


class AppContainer:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.database = Database(settings.database_url)
        self.storage = create_storage(settings)
        self.livekit = create_livekit_gateway(settings)
        self.voip_push = create_voip_push_gateway(settings)
        self.stt = create_stt_gateway(settings)
        self.extraction = create_extraction_gateway(settings)
        self.acoustics = UnconfiguredAcousticAnalyzer()
        self.signals = SignalService(settings)
        self.reports = ReportService()
        self.pipeline = ProcessingPipeline(
            settings,
            self.database,
            self.storage,
            self.stt,
            self.extraction,
            self.acoustics,
            self.signals,
        )
