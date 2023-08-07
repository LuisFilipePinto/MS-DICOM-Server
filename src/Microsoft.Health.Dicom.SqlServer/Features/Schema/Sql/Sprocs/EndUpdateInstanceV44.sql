﻿/*************************************************************
    Stored procedures for updating an instance status.
**************************************************************/
--
-- STORED PROCEDURE
--     EndUpdateInstanceV44
--
-- DESCRIPTION
--     Bulk update all instances in a study, creates new entry in changefeed and fileProperty for each new file added.
--
-- PARAMETERS
--     @partitionKey
--         * The partition key.
--     @studyInstanceUid
--         * The study instance UID.
--     @patientId
--         * The Id of the patient.
--     @patientName
--         * The name of the patient.
--     @patientBirthDate
--         * The patient's birth date.
--
-- RETURN VALUE
--     None
--
CREATE OR ALTER PROCEDURE dbo.EndUpdateInstanceV44
    @partitionKey                       INT,
    @studyInstanceUid                   VARCHAR(64),
    @patientId                          NVARCHAR(64) = NULL,
    @patientName                        NVARCHAR(325) = NULL,
    @patientBirthDate                   DATE = NULL,
    @insertFileProperties               dbo.FilePropertyTableType READONLY
AS
BEGIN
    SET NOCOUNT ON

    SET XACT_ABORT ON
    BEGIN TRANSACTION

        DECLARE @currentDate DATETIME2(7) = SYSUTCDATETIME()
        DECLARE @updatedInstances AS TABLE
               (PartitionKey INT,
                StudyInstanceUid VARCHAR(64),
                SeriesInstanceUid VARCHAR(64),
                SopInstanceUid VARCHAR(64),
                Watermark BIGINT,
                OriginalWatermark BIGINT,
                InstanceKey BIGINT)

        DELETE FROM @updatedInstances

        UPDATE dbo.Instance
        SET LastStatusUpdatedDate = @currentDate,
            OriginalWatermark = ISNULL(OriginalWatermark, Watermark),
            Watermark = NewWatermark,
            NewWatermark = NULL
        OUTPUT deleted.PartitionKey, @studyInstanceUid, deleted.SeriesInstanceUid, deleted.SopInstanceUid, deleted.NewWatermark, deleted.OriginalWatermark, deleted.InstanceKey INTO @updatedInstances
        WHERE PartitionKey = @partitionKey
            AND StudyInstanceUid = @studyInstanceUid
            AND Status = 1
            AND NewWatermark IS NOT NULL

        -- Only updating patient information in a study
        UPDATE dbo.Study
        SET PatientId = ISNULL(@patientId, PatientId), 
            PatientName = ISNULL(@patientName, PatientName), 
            PatientBirthDate = ISNULL(@patientBirthDate, PatientBirthDate)
        WHERE PartitionKey = @partitionKey
            AND StudyInstanceUid = @studyInstanceUid 

        -- The study does not exist. May be deleted
        IF @@ROWCOUNT = 0
            THROW 50404, 'Study does not exist', 1
        
        -- Delete from file properties any rows with "stale" watermarks if we will be inserting new ones
        IF EXISTS (SELECT 1 FROM @insertFileProperties)
        DELETE FP
        FROM dbo.FileProperty as FP
        INNER JOIN @updatedInstances U
        ON U.InstanceKey = FP.InstanceKey
        WHERE U.OriginalWatermark != FP.Watermark
        
        -- Insert new file properties from added blobs, @insertFileProperties will be empty when external store not 
        -- enabled
        INSERT INTO dbo.FileProperty 
        (InstanceKey, Watermark, FilePath, ETag)
        SELECT U.InstanceKey, I.Watermark, I.FilePath, I.ETag
        FROM @insertFileProperties I
        INNER JOIN @updatedInstances U
        ON U.Watermark = I.Watermark

        -- Insert into change feed table for update action type
        INSERT INTO dbo.ChangeFeed
        (Action, PartitionKey, StudyInstanceUid, SeriesInstanceUid, SopInstanceUid, OriginalWatermark)
        SELECT 2, PartitionKey, StudyInstanceUid, SeriesInstanceUid, SopInstanceUid, Watermark
        FROM @updatedInstances

        -- Update existing instance currentWatermark to latest and update file path
        UPDATE C
        SET CurrentWatermark = U.Watermark, FilePath = I.FilePath
        FROM dbo.ChangeFeed C
        JOIN @updatedInstances U
        ON C.PartitionKey = U.PartitionKey
            AND C.StudyInstanceUid = U.StudyInstanceUid
            AND C.SeriesInstanceUid = U.SeriesInstanceUid
            AND C.SopInstanceUid = U.SopInstanceUid
        LEFT OUTER JOIN @insertFileProperties I
        ON I.Watermark = U.Watermark

    COMMIT TRANSACTION
END